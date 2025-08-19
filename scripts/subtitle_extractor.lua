print("脚本已加载: subtitle_extractor.lua")
io.flush()

local utils = require 'mp.utils'
if not utils then
    print("错误: mp.utils 加载失败!")
    return
end
local msg = require 'mp.msg'

-- 用户配置
local ENABLE_REALTIME_TRANSCRIPTION = false -- 是否每次都进行 Whisper 转录，默认为 false
local TRANSCRIBE_IF_SINGLE_LINE_SUBTITLE = false -- 当字幕不是双行时，是否替代启动 Whisper 转录，默认为 false
local WHISPER_MODEL = "large-v2" -- Whisper 模型 tiny base small medium large-v2
local KEEP_TRANSCRIPTION_FILE = true -- 是否保留转录文件，默认保留
local IMAGE_FORMAT = "webp" -- 截图格式，可选 "webp" 或 "png"
local SCREENSHOT_SCALE = 480 -- 截图缩放高度，设置为数字（例如 720，480，360）则缩放到该高度，设置为 nil 则不缩放，保留原始分辨率
local WEBP_LOSSLESS = false -- WebP 格式是否使用无损压缩，true 为无损，false 为有损
local WEBP_QUALITY = 70 -- WebP 有损压缩质量，范围 0-100，数值越大质量越高。仅当 WEBP_LOSSLESS 为 false 时有效。
local WEBP_COMPRESSION_LEVEL = 6 -- WebP 压缩级别。有损模式(0-6)，无损模式(0-9)。数值越大，编码速度越慢，但压缩率越高（文件更小）。
local WEBP_PRESET = nil -- WebP 优化，可选 "default", "photo", "picture", "drawing", "icon", "text"。根据截图内容选择合适的预设可以优化质量和压缩效率，设置为 nil 则使用默认预设。
local AUDIO_CLIP_PADDING = 0.25 -- 音频剪辑前后填充的时间（秒）
local AUDIO_FORMAT = "ogg" -- 音频格式，例如 "mp3", "opus", "ogg", "m4a", "flac", "wav"
local o = {}
-- 全局变量，用于存储上一条实际显示过的字幕信息
local last_displayed_subtitle = {
    text = nil,
    s_corrected = nil,
    e_corrected = nil
}

-- 全局变量，用于存储上次处理的字幕信息，防止短时间内重复处理相同字幕
local last_sub_text = nil
local last_sub_start = nil
local last_sub_end = nil

-- 用于更新 last_displayed_subtitle 的回调函数，该变量存储上一条实际显示过的字幕信息
local function update_last_displayed_subtitle(property_name, current_sub_text_value)
    if current_sub_text_value and current_sub_text_value ~= "" then
        -- 字幕出现或发生变化
        local s_raw = mp.get_property_number('sub-start')
        local e_raw = mp.get_property_number('sub-end')

        if s_raw ~= nil and e_raw ~= nil then -- 确保时间戳有效
            local sub_delay = mp.get_property_native("sub-delay")
            local audio_delay = mp.get_property_native("audio-delay")
            -- 确保延迟值为数字，如果为nil则视为0
            sub_delay = type(sub_delay) == "number" and sub_delay or 0
            audio_delay = type(audio_delay) == "number" and audio_delay or 0

            last_displayed_subtitle.text = current_sub_text_value
            last_displayed_subtitle.s_corrected = s_raw + sub_delay - audio_delay
            last_displayed_subtitle.e_corrected = e_raw + sub_delay - audio_delay

            -- 可以取消下面这行注释进行调试，观察 last_displayed_subtitle 的更新
            msg.info(string.format("更新 last_displayed_subtitle: '%s' (%.3f - %.3f)", last_displayed_subtitle.text,
                last_displayed_subtitle.s_corrected, last_displayed_subtitle.e_corrected))
        else
            -- msg.info("观察到字幕文本，但其时间戳无效，未更新 last_displayed_subtitle")
        end
        -- else
        -- 字幕消失 (current_sub_text_value is nil or empty)
        -- 此时 last_displayed_subtitle 保持其之前的值，代表最后一条有效字幕
        -- msg.info("字幕消失，last_displayed_subtitle 保持不变: " .. (last_displayed_subtitle.text or "nil"))
    end
end

-- 注册字幕属性观察者，以更新 last_displayed_subtitle
mp.observe_property("sub-text", "string", update_last_displayed_subtitle)

-- 清理文件名中的非法字符
local function sanitize_filename(name)
    if not name then
        return "unknown" -- 如果名称为空，返回 "unknown"
    end

    -- 移除方括号 [ 和 ]，保留内部内容
    local cleaned_name = name:gsub("%[", ""):gsub("%]", "")

    -- 移除文件名和扩展名之间的点（如果存在）
    cleaned_name = cleaned_name:gsub("%.([^.]*)$", "%1")

    -- 将 Windows 文件名中的非法字符替换为下划线
    local illegal_chars = '[\\/:*?"<>|]'
    cleaned_name = cleaned_name:gsub(illegal_chars, '_')

    -- 移除首尾空格
    cleaned_name = cleaned_name:gsub("^%s*(.-)%s*$", "%1")

    -- 如果清理后为空，返回 "unnamed"
    if cleaned_name == "" then
        return "unnamed"
    end

    return cleaned_name
end

-- 获取用于文件名的基础名称（使用文件名，否则使用 media-title）
local function get_name()
    local filename = mp.get_property("filename")
    if filename and filename ~= "" then
        -- 提取不带扩展名的文件名
        local base_filename = filename:match("(.+)%..+$") or filename
        local sanitized_base = sanitize_filename(base_filename)
        -- 确保清理后的文件名不为空
        if sanitized_base ~= "unknown" and sanitized_base ~= "unnamed" and sanitized_base ~= "" then
            return sanitized_base
        end
    end

    -- 如果 filename 不可用或清理后为空，则尝试使用 media-title 这是给在线视频使用
    local mediatitle = mp.get_property("media-title")
    if mediatitle and mediatitle ~= "" then
        local sanitized_title = sanitize_filename(mediatitle)
        -- 确保清理后的标题不为空
        if sanitized_title ~= "unknown" and sanitized_title ~= "unnamed" and sanitized_title ~= "" then
            return sanitized_title
        end
    end

    -- 如果两者都不可用或清理后为空，返回默认值
    return "unnamed_file"
end

-- 为输入字符串生成一个简单的哈希值（用于生成唯一 ID）
local function generate_hash(input)
    local hash = 0
    for i = 1, #input do
        hash = (hash * 31 + string.byte(input, i)) % 1000000
    end
    return string.format("%06d", hash)
end

-- 比较两个浮点数是否在容差范围内相等
local function float_equals(a, b, tolerance)
    tolerance = tolerance or 0.00001 -- 默认容差
    return math.abs(a - b) < tolerance
end

-- 获取当前完整时间字符串（年月日时分秒）
local function get_current_time_string_full()
    local now = os.date("*t")
    return string.format("%04d%02d%02d%02d%02d%02d", now.year, now.month, now.day, now.hour, now.min, now.sec)
end

-- 获取当前日期字符串（年月日）
local function get_current_date_string()
    local now = os.date("*t")
    return string.format("%04d%02d%02d", now.year, now.month, now.day)
end

-- 创建音频片段
local function create_audio(s, e, dir, audio_name)
    if s == nil or e == nil then
        return nil -- 开始或结束时间无效
    end

    local destination = utils.join_path(dir, audio_name .. '.' .. AUDIO_FORMAT) -- 音频文件目标路径
    print("音频目标路径:", destination)
    s = s - AUDIO_CLIP_PADDING -- 应用开始时间填充
    local t = e - s + AUDIO_CLIP_PADDING -- 计算包含填充的音频时长
    local source = mp.get_property("path") -- 获取当前媒体文件路径
    local aid = mp.get_property("aid") -- 获取当前选定的音轨 ID
    local tracks_count = mp.get_property_number("track-list/count") -- 获取轨道总数
    -- 检查是否有外部音轨被选中
    for i = 1, tracks_count do
        local track_type = mp.get_property(string.format("track-list/%d/type", i))
        local track_selected = mp.get_property(string.format("track-list/%d/selected", i))
        if track_type == "audio" and track_selected == "yes" then
            -- 如果选中的是外部音轨，更新源文件路径和 aid
            if mp.get_property(string.format("track-list/%d/external-filename", i), o) ~= o then
                source = mp.get_property(string.format("track-list/%d/external-filename", i))
                aid = 'auto' -- 对于外部文件，通常让 mpv 自动选择
            end
            break
        end
    end

    -- 构建 mpv 命令以提取音频
    local cmd = {'run', 'mpv', source, '--loop-file=no', '--video=no', '--no-ocopy-metadata', '--no-sub',
                 '--audio-channels=1', string.format('--start=%.3f', s), string.format('--length=%.3f', t),
                 string.format('--aid=%s', aid), string.format('-o=%s', destination)}
    mp.commandv(table.unpack(cmd)) -- 执行命令
    return destination -- 返回创建的音频文件路径
end

-- 创建视频截图
local function create_screenshot(s, e, dir, snapshot_name)
    local source = mp.get_property("path") -- 获取当前媒体文件路径
    local img = utils.join_path(dir, snapshot_name .. '.' .. IMAGE_FORMAT) -- 截图文件目标路径
    print("截图路径:", img)
    -- 构建 mpv 命令以截取单帧图像
    local cmd = {'run', 'mpv', source, '--loop-file=no', '--audio=no', '--no-ocopy-metadata', '--no-sub', '--frames=1'}
    -- 根据 IMAGE_FORMAT 配置 WebP 或 PNG 选项
    if IMAGE_FORMAT == 'webp' then
        table.insert(cmd, '--ovc=libwebp') -- 使用 libwebp 编码器
        if WEBP_LOSSLESS then
            table.insert(cmd, '--ovcopts-add=lossless=1')
            table.insert(cmd, string.format('--ovcopts-add=compression_level=%d', math.min(WEBP_COMPRESSION_LEVEL, 9)))
        else
            table.insert(cmd, '--ovcopts-add=lossless=0')
            table.insert(cmd, string.format('--ovcopts-add=quality=%d', WEBP_QUALITY))
            table.insert(cmd, string.format('--ovcopts-add=compression_level=%d', math.min(WEBP_COMPRESSION_LEVEL, 6)))
        end
        if WEBP_PRESET and WEBP_PRESET ~= "default" then
            table.insert(cmd, string.format('--ovcopts-add=preset=%s', WEBP_PRESET)) -- WebP 预设
        end
    elseif IMAGE_FORMAT == 'png' then
        table.insert(cmd, '--vf-add=format=rgb24') -- PNG 通常需要 RGB24 格式
    end
    -- 如果设置了缩放，添加视频滤镜
    if SCREENSHOT_SCALE then
        -- 使用 -1 让 ffmpeg 自动计算宽度以保持宽高比
        table.insert(cmd, string.format('--vf-add=scale=-1:%d', SCREENSHOT_SCALE))
    end
    table.insert(cmd, string.format('--start=%.3f', s)) -- 设置截图时间点（使用字幕开始时间）
    table.insert(cmd, string.format('-o=%s', img)) -- 设置输出文件
    mp.commandv(table.unpack(cmd)) -- 执行命令
end

-- 使用 Whisper 进行音频转录
local function whisper_transcribe(audio_path)
    local start_time_func = os.clock() -- 记录函数开始时间（用于调试）

    local whisper_output_path = audio_path:gsub("%." .. AUDIO_FORMAT .. "$", ".txt") -- Whisper 输出的文本文件路径
    local audio_dir = audio_path:match("(.*/)[^/]+") -- 从音频路径中提取目录

    if not audio_dir then
        msg.error("无法从音频路径中提取目录: " .. audio_path)
        mp.osd_message("无法从音频路径中提取目录!", 5)
        return nil
    end

    mp.osd_message("开始 Whisper 转录...", 3)

    -- 构建 Whisper 命令行基础部分
    local cmd_base = string.format(
        'whisper-ctranslate2 ' .. '--model %s ' .. '--output_format txt ' .. '--language ja ' .. '--device cpu ' ..
            '--output_dir "%s" ' .. '"%s"', WHISPER_MODEL, audio_dir, audio_path)

    -- 总是使用 Windows 的命令格式
    local cmd = 'start /min cmd /c "' .. cmd_base .. '"'

    print("Whisper 命令: ", cmd)
    local handle = io.popen(cmd .. " 2>&1")
    local output = handle:read("*all")
    local exit_code = handle:close()

    mp.osd_message("Whisper 转录命令已执行", 2)

    print("[调试] Whisper 退出代码: ", exit_code, ", 类型:", type(exit_code))

    -- 检查 Whisper 是否成功执行（退出代码 0 或 true 被视为成功）
    if exit_code == 0 or exit_code == true then
        msg.info("Whisper 转录命令已执行 (退出代码被认为是成功)")
        msg.info("Whisper 输出: " .. output)
        mp.osd_message("Whisper 命令执行成功", 2)

        local whisper_sub = "" -- 用于存储转录结果
        local max_retries = 5 -- 最大重试次数
        local base_delay = 0.1 -- 基础延迟时间（秒）

        -- 尝试读取 Whisper 输出文件，带重试机制
        for i = 1, max_retries do
            local success, content = pcall(function()
                mp.osd_message("读取 Whisper 输出文件...", 2)
                local file = io.open(whisper_output_path, "r", "encoding:utf-8")
                if file then
                    local read_success, file_content = pcall(file.read, file, "*all")
                    file:close()
                    if read_success then
                        print("[调试] 文件读取成功: " .. whisper_output_path)
                        print("[调试] 文件内容: ", file_content)
                        whisper_sub = file_content
                        mp.osd_message("Whisper 输出文件读取成功", 2)
                        return true, file_content -- 读取成功
                    else
                        print("[调试] 文件读取失败: ", whisper_output_path, file_content)
                        mp.osd_message("读取 Whisper 输出文件失败", 5)
                        return false, file_content -- 读取失败
                    end
                end
                print("[调试] 文件打开失败: " .. whisper_output_path)
                mp.osd_message("打开 Whisper 输出文件失败", 5)
                return false, nil -- 文件打开失败
            end)
            if success then
                break -- 成功读取，跳出重试循环
            else
                -- 计算带抖动的指数退避延迟
                local delay = base_delay * (2 ^ (i - 1))
                local jitter = math.random() * 0.05
                delay = delay + jitter
                mp.utils.sleep(delay) -- 等待
                msg.warn("重试读取文件。尝试次数: " .. i .. "/" .. max_retries .. ". 等待 " .. delay ..
                             " 秒。")
                mp.osd_message(string.format("重试读取 Whisper 输出文件 (%d/%d)", i, max_retries), 2)
            end
        end
        print("[调试] whisper_sub 准备返回的值: ", whisper_sub)
        -- 清理转录结果：将换行符替换为逗号，移除末尾可能存在的逗号
        whisper_sub = whisper_sub:gsub("[\r\n]+", ",")
        if whisper_sub:sub(-1) == "," then
            whisper_sub = whisper_sub:sub(1, -2)
        end

        -- 如果不保留转录文件，则删除它
        if not KEEP_TRANSCRIPTION_FILE then
            os.remove(whisper_output_path)
            print("[调试] 已删除 Whisper 转录文件: " .. whisper_output_path)
        end

        mp.osd_message("Whisper 转录成功完成", 2)
        return whisper_sub -- 返回清理后的转录文本
    else
        -- Whisper 执行失败
        msg.error("Whisper 转录失败，退出代码: " .. tostring(exit_code))
        msg.error("Whisper 错误输出: " .. output)
        mp.osd_message("Whisper 转录失败", 5)
        mp.osd_message("请检查控制台以获取详细的 Whisper 错误输出", 5)
        return "Whisper转录失败" -- 返回失败信息
    end
end

-- 主函数：提取字幕、截图、音频，并保存到 TSV 文件
local function extract_and_save()

    msg.info("extract_and_save 函数被调用")
    io.flush()

    local text_to_process
    local s_to_process
    local e_to_process

    local current_on_screen_sub_text = mp.get_property("sub-text")

    if current_on_screen_sub_text and current_on_screen_sub_text ~= "" then
        -- 情况1：当前屏幕上有字幕
        text_to_process = current_on_screen_sub_text
        msg.info("检测到当前屏幕字幕: " .. text_to_process)
        print("原始字幕文本:", text_to_process)

        local s_raw = mp.get_property_number('sub-start')
        local e_raw = mp.get_property_number('sub-end')
        -- print("字幕开始时间 (原始):", s_raw) -- 调试信息
        -- print("字幕结束时间 (原始):", e_raw) -- 调试信息

        if s_raw == nil or e_raw == nil then
            msg.warn("无法提取当前屏幕字幕的时间戳。")
            mp.osd_message("无法提取当前字幕时间戳", 3)
            return
        end

        local sub_delay = mp.get_property_native("sub-delay")
        local audio_delay = mp.get_property_native("audio-delay")
        sub_delay = type(sub_delay) == "number" and sub_delay or 0
        audio_delay = type(audio_delay) == "number" and audio_delay or 0

        s_to_process = s_raw + sub_delay - audio_delay
        e_to_process = e_raw + sub_delay - audio_delay
        -- print("字幕时间 (校正后): s=" .. s_to_process .. ", e=" .. e_to_process) -- 调试信息

        -- 针对 “当前屏幕字幕” 与 “脚本上次处理的字幕 (last_sub_text)” 的重复性检查
        -- 这是为了防止用户快速连按快捷键导致对同一条正在显示的字幕重复处理
        if last_sub_text == text_to_process and last_sub_start and float_equals(s_to_process, last_sub_start) and
            last_sub_end and float_equals(e_to_process, last_sub_end) then
            msg.info("当前屏幕字幕与脚本上次处理的字幕完全相同，跳过保存。")
            mp.osd_message("重复字幕，跳过保存", 3)
            io.flush()
            return
        end
    else
        -- 情况2：当前屏幕上没有字幕，尝试使用 last_displayed_subtitle (上一条实际显示过的字幕)
        msg.info("当前屏幕无字幕。尝试使用上一条实际显示过的字幕 (last_displayed_subtitle)。")
        if last_displayed_subtitle.text and last_displayed_subtitle.s_corrected ~= nil and
            last_displayed_subtitle.e_corrected ~= nil then
            text_to_process = last_displayed_subtitle.text
            s_to_process = last_displayed_subtitle.s_corrected -- 这些已经是校正过的值
            e_to_process = last_displayed_subtitle.e_corrected -- 这些已经是校正过的值

            msg.info(string.format("使用上一条显示过的字幕: '%s' (时间: %.3f - %.3f)", text_to_process,
                s_to_process, e_to_process))
            mp.osd_message("使用上一条显示过的字幕", 3)

            -- 当使用 last_displayed_subtitle 时，我们允许用户处理这条字幕，
            -- 即便它可能与 last_sub_text (脚本上次处理的字幕) 相同。
            -- 后续的文件内重复检查 (skip_write) 仍会处理最终是否写入文件的问题。
        else
            msg.info(
                "当前屏幕无字幕，且未能获取到上一条显示过的字幕 (last_displayed_subtitle 为空或不完整)。")
            mp.osd_message("没有字幕可供处理", 3)
            io.flush()
            return
        end
    end

    -- 将确定的字幕信息赋值给函数后续逻辑使用的变量
    local text = text_to_process
    local s = s_to_process
    local e = e_to_process

    -- 获取用户主目录
    local home_dir = os.getenv("HOME") or os.getenv("USERPROFILE")
    if not home_dir then
        msg.error("无法获取用户主目录")
        mp.osd_message("错误：无法定位用户目录", 3)
        return
    end

    local folder_name = "mpv_subtitle_extract" -- 输出文件夹名称
    local folder_path = utils.join_path(home_dir, folder_name) -- 输出文件夹完整路径

    -- 创建输出文件夹（如果不存在）
    if utils.file_info(folder_path) == nil then
        -- 使用 Windows 的 mkdir 命令
        local cmd = string.format('mkdir "%s"', folder_path)

        local handle = io.popen(cmd)
        if handle then
            handle:close()
        else
            msg.error("创建文件夹失败: " .. folder_path)
            mp.osd_message("创建文件夹失败", 3)
            return
        end
    end

    -- 获取并清理基础文件名
    local base_filename = get_name()
    local sanitized_filename = sanitize_filename(base_filename)
    print("清理后的文件名:", sanitized_filename)

    local filename = utils.join_path(folder_path, base_filename .. ".tsv") -- TSV 文件完整路径
    print("完整文件路径:", filename)
    local skip_write = false -- 标记是否因文件内重复而跳过写入

    -- 检查 TSV 文件是否存在，并进行文件内重复检查
    local file = io.open(filename, "r", "encoding:utf-8")
    if not file then -- 文件不存在
        msg.info("文件不存在，创建新文件并写入表头。")
        mp.osd_message("文件不存在，创建新文件并写入表头。", 3)
        file = io.open(filename, "w+", "encoding:utf-8") -- 创建文件
        if not file then
            msg.error("创建文件失败: " .. filename)
            mp.osd_message("创建文件失败", 3)
            return
        end
        -- 写入 TSV 表头
        file:write(
            "note_id\ttop_sub\tbottom_sub\tsnapshot\taudio\tMainDefinition\tsubtitles\tstart_time\tend_time\twhisper_sub\n")
        file:close()
        file = nil -- 关闭文件句柄
    else -- 文件已存在
        msg.info("文件已存在，读取内容进行重复检查 (UTF-8 编码).")
        io.flush()
        file:close() -- 先关闭只读句柄
        file = nil
        file = io.open(filename, "r", "encoding:utf-8") -- 重新以只读打开进行检查
        if not file then
            msg.error("打开文件失败 (读取模式, UTF-8): " .. filename)
            mp.osd_message("文件打开失败", 3)
            return
        end
        -- 逐行读取文件检查重复
        for line in file:lines() do
            -- 使用 LPEG 或 string.match 解析 TSV 行
            local _, _, _, _, _, _, existing_subtitle, existing_start_time, existing_end_time = line:match(
                "([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]+)\t([^\t]+)\t([^\t]+)")
            if existing_subtitle then
                -- 仅比较字幕文本和时间戳
                if existing_subtitle == text and float_equals(s, tonumber(existing_start_time)) and
                    float_equals(e, tonumber(existing_end_time)) then
                    skip_write = true -- 标记为重复
                    msg.info("发现重复条目 (文件内)，跳过: " .. text)
                    mp.osd_message("文件内重复字幕，跳过", 3)
                    io.flush()
                    break -- 找到重复项，无需继续检查
                end
            end
        end
        file:close() -- 关闭文件

        -- 如果标记为跳过，则直接返回
        if skip_write then
            msg.info("文件内重复条目，跳过保存: " .. text)
            io.flush()
            return
        end
    end

    -- 如果不需要跳过写入
    if not skip_write then
        -- 以追加模式打开文件
        file = io.open(filename, "a+", "encoding:utf-8")
        if not file then
            msg.error("打开文件失败 (追加模式, UTF-8): " .. filename)
            mp.osd_message("文件打开失败", 3)
            return
        end

        -- 生成唯一 ID 和文件名哈希
        local current_time_full = get_current_time_string_full()
        local current_date = get_current_date_string()
        local note_id_hash = generate_hash(current_time_full)
        local note_id = string.format("%s_%s", current_date, note_id_hash) -- 笔记 ID

        local snapshot_hash = generate_hash(sanitized_filename .. tostring(s) .. tostring(e) .. "snapshot")
        local audio_hash = generate_hash(sanitized_filename .. tostring(s) .. tostring(e) .. "sent_audio")
        local snapshot_name = sanitized_filename .. "_snapshot_" .. snapshot_hash -- 截图文件名（不含扩展名）
        local audio_name = sanitized_filename .. "_sent_audio_" .. audio_hash -- 音频文件名（不含扩展名）

        -- 创建截图和音频
        create_screenshot(s, e, folder_path, snapshot_name)
        local audio_path = create_audio(s, e, folder_path, audio_name)
        local whisper_sub = "" -- 初始化 Whisper 转录结果

        local top_sub = ""
        local bottom_sub = ""
        local lines = {}
        for line in text:gmatch("([^\n]+)") do
            table.insert(lines, line)
        end
        if #lines >= 1 then
            top_sub = lines[1]:gsub("\t", ",") -- 将制表符替换为逗号，避免破坏 TSV 格式
        end
        if #lines >= 2 then
            top_sub = lines[1]:gsub("\t", ",") -- 将制表符替换为逗号，避免破坏 TSV 格式
            bottom_sub = lines[2]:gsub("\t", ",") -- 将制表符替换为逗号，避免破坏 TSV 格式
        end

        -- 判断是否需要进行 Whisper 转录
        local should_transcribe = ENABLE_REALTIME_TRANSCRIPTION
        if not should_transcribe and TRANSCRIBE_IF_SINGLE_LINE_SUBTITLE then
            -- 如果ENABLE_REALTIME_TRANSCRIPTION为false，但TRANSCRIBE_IF_SINGLE_LINE_SUBTITLE为true，
            -- 并且不是双行字幕，则进行转录
            if not (top_sub ~= "" and bottom_sub ~= "") then
                msg.info(
                    "检测到非双行字幕，且 'TRANSCRIBE_IF_SINGLE_LINE_SUBTITLE' 为 true，将进行 Whisper 转录。")
                should_transcribe = true
            end
        end

        -- 如果启用了实时转录，则调用 Whisper
        if should_transcribe then
            if audio_path then -- 确保音频文件已成功创建
                whisper_sub = whisper_transcribe(audio_path) or "Whisper转录失败" -- 获取转录结果，失败则记录
            else
                whisper_sub = "音频创建失败"
            end
        end

        -- 准备写入 TSV 的数据
        local sanitized_text = text:gsub("[\n\t]", " ") -- 将原始字幕中的换行符和制表符替换为空格
        local snapshot_value = string.format('<img src="%s">', snapshot_name .. "." .. IMAGE_FORMAT) -- Anki 图片字段格式
        local audio_value = string.format('[sound:%s]', audio_name .. "." .. AUDIO_FORMAT) -- Anki 音频字段格式

        -- 写入数据行到 TSV 文件，注意 MainDefinition 列暂时为空字符串 ""
        file:write(string.format("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", note_id, top_sub, bottom_sub,
            snapshot_value, audio_value, "", sanitized_text, s, e, whisper_sub))
        file:close() -- 关闭文件
        msg.info("数据已保存到: " .. filename)
        mp.osd_message(string.format("字幕已保存到: %s", filename), 3)

        -- 更新上次处理的字幕信息
        last_sub_text = text
        last_sub_start = s
        last_sub_end = e
    else
        -- 此处逻辑理论上不会执行，因为前面已经 return 了，但保留以防万一
        msg.info("文件内重复条目，跳过保存: " .. text)
        io.flush()
    end

end

-- 绑定快捷键 J
mp.add_key_binding("j", "extract-and-save", extract_and_save)

io.flush()
