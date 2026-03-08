--@description: pmc - pack-my-code, a minimalist code context packaging tool
--@author: WaterRun
--@file: pmc.lua
--@date: 2026-03-08
--@updated: 2026-03-08

---@class PmcOptions
---@field target_dir string
---@field exclude_patterns string[]
---@field include_patterns string[]
---@field ignore_gitignore boolean
---@field with_tree boolean
---@field with_stats boolean
---@field wrap_mode "md"|"nil"|"block"
---@field path_mode "relative"|"name"|"absolute"
---@field yaml_mode boolean
---@field output_file string|nil
---@field show_version boolean
---@field show_help boolean
---@field user_set_t boolean
---@field user_set_s boolean
---@field user_set_w boolean
---@field user_set_p boolean

---@class FileItem
---@field abs_path string
---@field rel_target string
---@field display_path string
---@field content string
---@field line_count integer
---@field ext_key string

---@class TreeNode
---@field name string
---@field kind "dir"|"file"
---@field order integer
---@field rel_path string|nil
---@field children table<string, TreeNode>|nil
---@field files table<string, TreeNode>|nil

--@description: constants
local VERSION = "6024" -- 2[6][03][*][08]

--@description: known no-extension files for stats grouping
local KNOWN_NO_EXT = {
    ["makefile"] = true,
    ["dockerfile"] = true,
    ["vagrantfile"] = true,
    ["jenkinsfile"] = true,
    ["readme"] = true,
    ["license"] = true,
    ["copying"] = true,
    ["changelog"] = true
}

--@description: path separator by runtime platform
local DIR_SEP = package.config:sub(1, 1)
local IS_WINDOWS = (DIR_SEP == "\\")

--@description: fail with standardized error format
--@param message string
--@return: nil
local function fail(message)
    io.stderr:write(string.format("err:( %s )\n", message))
    os.exit(1)
end

--@description: trim leading and trailing spaces
--@param s string
--@return: string
local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--@description: normalize path separators to forward slash
--@param p string
--@return: string
local function normalizePath(p)
    local s = p:gsub("\\", "/")
    s = s:gsub("/+", "/")
    if #s > 1 then
        s = s:gsub("/$", "")
    end
    return s
end

--@description: check whether string starts with prefix
--@param s string
--@param prefix string
--@return: boolean
local function startsWith(s, prefix)
    return s:sub(1, #prefix) == prefix
end

--@description: check whether string ends with suffix
--@param s string
--@param suffix string
--@return: boolean
local function endsWith(s, suffix)
    if suffix == "" then
        return true
    end
    return s:sub(- #suffix) == suffix
end

--@description: split string by delimiter char
--@param s string
--@param delim string
--@return: string[]
local function splitByChar(s, delim)
    local out = {}
    local start_i = 1
    while true do
        local i, j = s:find(delim, start_i, true)
        if not i then
            table.insert(out, s:sub(start_i))
            break
        end
        table.insert(out, s:sub(start_i, i - 1))
        start_i = j + 1
    end
    return out
end

--@description: basename from normalized path
--@param p string
--@return: string
local function baseName(p)
    local s = normalizePath(p)
    local i = s:match("^.*()/")
    if i then
        return s:sub(i + 1)
    end
    return s
end

--@description: shell quote for current platform
--@param s string
--@return: string
local function shellQuote(s)
    if IS_WINDOWS then
        return "\"" .. s:gsub("\"", "\"\"") .. "\""
    end
    return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

--@description: run shell command and capture all stdout
--@param cmd string
--@return: boolean
--@return: string
--@return: string|integer
local function runCommand(cmd)
    local pipe, err = io.popen(cmd, "r")
    if not pipe then
        return false, "", err or "popen failed"
    end
    local data = pipe:read("*a") or ""
    local ok, why, code = pipe:close()
    if ok == nil then
        return false, data, code or why or "command failed"
    end
    return true, data, 0
end

--@description: get absolute path using shell built-ins
--@param p string
--@return: string
local function getAbsolutePath(p)
    if IS_WINDOWS then
        local cmd = "cd /d " .. shellQuote(p) .. " && cd"
        local ok, out = runCommand(cmd)
        if not ok then
            fail("cannot resolve absolute path: " .. p)
        end
        local line = trim(out:gsub("\r", ""))
        if line == "" then
            fail("cannot resolve absolute path: " .. p)
        end
        return normalizePath(line)
    end
    local cmd = "cd " .. shellQuote(p) .. " && pwd"
    local ok, out = runCommand(cmd)
    if not ok then
        fail("cannot resolve absolute path: " .. p)
    end
    local line = trim(out)
    if line == "" then
        fail("cannot resolve absolute path: " .. p)
    end
    return normalizePath(line)
end

--@description: get current working directory
--@return: string
local function getCwd()
    if IS_WINDOWS then
        local ok, out = runCommand("cd")
        if not ok then
            fail("cannot get current directory")
        end
        return normalizePath(trim(out:gsub("\r", "")))
    end
    local ok, out = runCommand("pwd")
    if not ok then
        fail("cannot get current directory")
    end
    return normalizePath(trim(out))
end

--@description: parse comma-separated patterns
--@param raw string|nil
--@return: string[]
local function parsePatternList(raw)
    local patterns = {}
    if not raw or raw == "" then
        return patterns
    end
    local parts = splitByChar(raw, ",")
    for _, part in ipairs(parts) do
        local p = trim(part)
        if p ~= "" then
            p = normalizePath(p)
            table.insert(patterns, p)
        end
    end
    return patterns
end

--@description: escape lua pattern chars except glob symbols
--@param s string
--@return: string
local function globToLuaPattern(s)
    local out = { "^" }
    local i = 1
    while i <= #s do
        local ch = s:sub(i, i)
        if ch == "*" then
            table.insert(out, ".*")
        elseif ch == "?" then
            table.insert(out, ".")
        elseif ch:match("[%^%$%(%)%%%.%[%]%+%-%]") then
            table.insert(out, "%" .. ch)
        else
            table.insert(out, ch)
        end
        i = i + 1
    end
    table.insert(out, "$")
    return table.concat(out)
end

--@description: detect wildcard usage in a pattern
--@param p string
--@return: boolean
local function hasWildcard(p)
    return p:find("*", 1, true) ~= nil or p:find("?", 1, true) ~= nil
end

--@description: check if a segment exists in path
--@param rel_path string
--@param seg string
--@return: boolean
local function hasPathSegment(rel_path, seg)
    local parts = splitByChar(rel_path, "/")
    for i = 1, (#parts - 1) do
        if parts[i] == seg then
            return true
        end
    end
    return false
end

--@description: match one include/exclude pattern against target-relative path
--@param rel_path string
--@param pattern string
--@return: boolean
local function matchOnePattern(rel_path, pattern)
    local rp = normalizePath(rel_path)
    local pt = normalizePath(pattern)
    local is_dir_pattern = endsWith(pt, "/")
    local basename = baseName(rp)

    if is_dir_pattern then
        local d = pt:sub(1, -2)
        if d == "" then
            return false
        end
        if d:find("/", 1, true) then
            return startsWith(rp, d .. "/")
        end
        if startsWith(rp, d .. "/") then
            return true
        end
        return hasPathSegment(rp, d)
    end

    if pt:find("/", 1, true) then
        if hasWildcard(pt) then
            return rp:match(globToLuaPattern(pt)) ~= nil
        end
        return rp == pt
    end

    if hasWildcard(pt) then
        local lp = globToLuaPattern(pt)
        if basename:match(lp) then
            return true
        end
        return rp:match(lp) ~= nil
    end

    return basename == pt or rp == pt
end

--@description: pattern list matcher (any-match)
--@param rel_path string
--@param patterns string[]
--@return: boolean
local function matchPatterns(rel_path, patterns)
    for _, p in ipairs(patterns) do
        if matchOnePattern(rel_path, p) then
            return true
        end
    end
    return false
end

--@description: check if git is available
--@return: boolean
local function hasGit()
    local ok = runCommand("git --version")
    return ok
end

--@description: return true if path has extension
--@param name string
--@return: boolean
local function hasExtension(name)
    local i = name:match("^.*()%.")
    if not i then
        return false
    end
    if i == 1 then
        return false
    end
    return i < #name
end

--@description: extension stats key with known/unknown no-extension split
--@param rel_path string
--@return: string
local function detectExtKey(rel_path)
    local bn = baseName(rel_path)
    local lower_bn = bn:lower()
    if not hasExtension(bn) then
        if KNOWN_NO_EXT[lower_bn] then
            return "[no_ext:known]"
        end
        return "[no_ext:unknown]"
    end
    local ext = bn:match("^.+(%.[^%.]+)$")
    if not ext then
        return "[no_ext:unknown]"
    end
    return ext:lower()
end

--@description: count text lines
--@param content string
--@return: integer
local function countLines(content)
    if content == "" then
        return 0
    end
    local n = 0
    local i = 1
    while true do
        local p = content:find("\n", i, true)
        if not p then
            break
        end
        n = n + 1
        i = p + 1
    end
    if content:sub(-1) == "\n" then
        return n
    end
    return n + 1
end

--@description: read file as binary-safe string
--@param abs_path string
--@return: string|nil
--@return: string|nil
local function readFile(abs_path)
    local f, err = io.open(abs_path, "rb")
    if not f then
        return nil, err
    end
    local data = f:read("*a")
    f:close()
    return data or "", nil
end

--@description: text file check by null-byte sniffing
--@param data string
--@return: boolean
local function isTextContent(data)
    if data:find("\0", 1, true) then
        return false
    end
    return true
end

--@description: list files using git (respect .gitignore)
--@param target_abs string
--@return: string[]
local function listFilesWithGit(target_abs)
    if not hasGit() then
        fail("git is required for default mode; use -r to scan directly")
    end

    local ok_repo, repo_out = runCommand("git -C " .. shellQuote(target_abs) .. " rev-parse --show-toplevel")
    if not ok_repo then
        fail("target is not inside a git work tree; use -r to scan directly")
    end
    local repo_root = normalizePath(trim(repo_out:gsub("\r", "")))
    if repo_root == "" then
        fail("failed to get git repository root")
    end

    local rel_cmd
    if IS_WINDOWS then
        rel_cmd = "cd /d " .. shellQuote(repo_root) .. " && cd"
    else
        rel_cmd = "cd " .. shellQuote(repo_root) .. " && pwd"
    end
    local ok_root, root_out = runCommand(rel_cmd)
    if not ok_root then
        fail("failed to resolve repository root")
    end
    local root_abs = normalizePath(trim(root_out:gsub("\r", "")))
    local target_norm = normalizePath(target_abs)

    local rel_target = ""
    if target_norm ~= root_abs then
        if not startsWith(target_norm, root_abs .. "/") then
            fail("target path is outside repository root")
        end
        rel_target = target_norm:sub(#root_abs + 2)
    end

    local ok_list, list_out = runCommand(
        "git -C " .. shellQuote(root_abs) .. " ls-files -z --cached --others --exclude-standard --full-name"
    )
    if not ok_list then
        fail("failed to list files through git")
    end

    local files = {}
    for item in list_out:gmatch("([^%z]+)") do
        local rel_repo = normalizePath(item)
        if rel_repo ~= "" then
            if rel_target == "" then
                table.insert(files, normalizePath(root_abs .. "/" .. rel_repo))
            else
                if rel_repo == rel_target or startsWith(rel_repo, rel_target .. "/") then
                    table.insert(files, normalizePath(root_abs .. "/" .. rel_repo))
                end
            end
        end
    end

    return files
end

--@description: list files by direct recursive scan (-r mode)
--@param target_abs string
--@return: string[]
local function listFilesDirect(target_abs)
    local cmd
    if IS_WINDOWS then
        cmd = "dir /a-d /s /b " .. shellQuote(target_abs)
    else
        cmd = "find " .. shellQuote(target_abs) .. " -type f -print"
    end

    local ok, out = runCommand(cmd)
    if not ok then
        fail("failed to scan directory: " .. target_abs)
    end

    local files = {}
    out = out:gsub("\r", "")
    for line in out:gmatch("([^\n]+)") do
        local p = trim(line)
        if p ~= "" then
            table.insert(files, normalizePath(p))
        end
    end
    return files
end

--@description: split normalized path into segments
--@param p string
--@return: string[]
local function splitPathSegments(p)
    local segs = {}
    for seg in normalizePath(p):gmatch("[^/]+") do
        table.insert(segs, seg)
    end
    return segs
end

--@description: compute relative path from base to target (both absolute normalized)
--@param base_abs string
--@param target_abs string
--@return: string
local function relativePath(base_abs, target_abs)
    local base = splitPathSegments(base_abs)
    local targ = splitPathSegments(target_abs)

    local i = 1
    while i <= #base and i <= #targ and base[i] == targ[i] do
        i = i + 1
    end

    local out = {}
    for _ = i, #base do
        table.insert(out, "..")
    end
    for j = i, #targ do
        table.insert(out, targ[j])
    end

    if #out == 0 then
        return "."
    end
    return table.concat(out, "/")
end

--@description: convert absolute path to target-relative path
--@param target_abs string
--@param file_abs string
--@return: string
local function toTargetRelative(target_abs, file_abs)
    local t = normalizePath(target_abs)
    local f = normalizePath(file_abs)
    if f == t then
        return "."
    end
    if startsWith(f, t .. "/") then
        return f:sub(#t + 2)
    end
    return relativePath(t, f)
end

--@description: render display path in selected mode
--@param path_mode "relative"|"name"|"absolute"
--@param cwd_abs string
--@param file_abs string
--@return: string
local function formatDisplayPath(path_mode, cwd_abs, file_abs)
    if path_mode == "absolute" then
        return normalizePath(file_abs)
    end
    if path_mode == "name" then
        return baseName(file_abs)
    end
    local rel = relativePath(cwd_abs, normalizePath(file_abs))
    return rel
end

--@description: create default options
--@return: PmcOptions
local function makeDefaultOptions()
    return {
        target_dir = ".",
        exclude_patterns = {},
        include_patterns = {},
        ignore_gitignore = false,
        with_tree = false,
        with_stats = false,
        wrap_mode = "md",
        path_mode = "relative",
        yaml_mode = false,
        output_file = nil,
        show_version = false,
        show_help = false,
        user_set_t = false,
        user_set_s = false,
        user_set_w = false,
        user_set_p = false
    }
end

--@description: parse CLI arguments
--@param argv string[]
--@return: PmcOptions
local function parseArgs(argv)
    local opt = makeDefaultOptions()
    local i = 1
    local target_set = false

    while i <= #argv do
        local a = argv[i]

        if a == "-v" then
            opt.show_version = true
            i = i + 1
        elseif a == "-h" or a == "--help" then
            opt.show_help = true
            i = i + 1
        elseif a == "-x" then
            local val = argv[i + 1]
            if not val then
                fail("missing value for -x")
            end
            local pats = parsePatternList(val)
            for _, p in ipairs(pats) do
                table.insert(opt.exclude_patterns, p)
            end
            i = i + 2
        elseif a == "-m" then
            local val = argv[i + 1]
            if not val then
                fail("missing value for -m")
            end
            local pats = parsePatternList(val)
            for _, p in ipairs(pats) do
                table.insert(opt.include_patterns, p)
            end
            i = i + 2
        elseif a == "-r" then
            opt.ignore_gitignore = true
            i = i + 1
        elseif a == "-t" then
            opt.with_tree = true
            opt.user_set_t = true
            i = i + 1
        elseif a == "-s" then
            opt.with_stats = true
            opt.user_set_s = true
            i = i + 1
        elseif a == "-w" then
            local val = argv[i + 1]
            if not val then
                fail("missing value for -w")
            end
            val = trim(val)
            if val ~= "md" and val ~= "nil" and val ~= "block" then
                fail("invalid -w mode: " .. val)
            end
            opt.wrap_mode = val
            opt.user_set_w = true
            i = i + 2
        elseif a == "-p" then
            local val = argv[i + 1]
            if not val then
                fail("missing value for -p")
            end
            val = trim(val)
            if val == "releative" then
                val = "relative"
            end
            if val ~= "relative" and val ~= "name" and val ~= "absolute" then
                fail("invalid -p mode: " .. val)
            end
            opt.path_mode = val
            opt.user_set_p = true
            i = i + 2
        elseif a == "-y" then
            opt.yaml_mode = true
            i = i + 1
        elseif a == "-o" then
            local val = argv[i + 1]
            if not val or trim(val) == "" then
                fail("missing value for -o")
            end
            opt.output_file = trim(val)
            i = i + 2
        elseif startsWith(a, "-") then
            fail("unknown option: " .. a)
        else
            if target_set then
                fail("multiple target directories are not allowed")
            end
            opt.target_dir = a
            target_set = true
            i = i + 1
        end
    end

    if opt.yaml_mode then
        if opt.user_set_t or opt.user_set_s or opt.user_set_w or opt.user_set_p then
            fail("-y cannot be used with -t, -s, -w, or -p")
        end
        if not opt.output_file then
            fail("yaml mode requires -o with .yaml or .yml file")
        end
        local lower = opt.output_file:lower()
        if not (endsWith(lower, ".yaml") or endsWith(lower, ".yml")) then
            fail("yaml output file must end with .yaml or .yml")
        end
    end

    return opt
end

--@description: print help text
--@return: nil
local function printHelp()
    local msg = [[pmc - pack-my-code

Usage:
  pmc [target-directory] [options]

Options:
  -v               Show version
  -x "<patterns>"  Exclude patterns (comma-separated)
  -m "<patterns>"  Include-only patterns (comma-separated), lower priority than -x
  -r               Ignore .gitignore (direct scan)
  -t               Output tree at beginning
  -s               Output statistics at end
  -w <mode>        Wrap mode: md | nil | block
  -p <mode>        Path mode: relative | name | absolute
  -y               YAML mode (cannot combine with -t -s -w -p)
  -o <file>        Redirect output to file
  -h, --help       Show help
]]
    io.write(msg)
end

--@description: filter files by include/exclude patterns and text-only rule
--@param abs_files string[]
--@param target_abs string
--@param opt PmcOptions
--@param cwd_abs string
--@return: FileItem[]
local function buildFileItems(abs_files, target_abs, opt, cwd_abs)
    local items = {}

    table.sort(abs_files, function(a, b)
        return normalizePath(a) < normalizePath(b)
    end)

    for _, abs_path in ipairs(abs_files) do
        local rel_target = toTargetRelative(target_abs, abs_path)
        if rel_target ~= "." then
            local include_ok = true
            if #opt.include_patterns > 0 then
                include_ok = matchPatterns(rel_target, opt.include_patterns)
            end

            local exclude_hit = false
            if #opt.exclude_patterns > 0 then
                exclude_hit = matchPatterns(rel_target, opt.exclude_patterns)
            end

            if include_ok and not exclude_hit then
                local data, err = readFile(abs_path)
                if data == nil then
                    fail("cannot read file: " .. abs_path .. " (" .. tostring(err) .. ")")
                end
                if isTextContent(data) then
                    local item = {
                        abs_path = normalizePath(abs_path),
                        rel_target = normalizePath(rel_target),
                        display_path = formatDisplayPath(opt.path_mode, cwd_abs, abs_path),
                        content = data,
                        line_count = countLines(data),
                        ext_key = detectExtKey(rel_target)
                    }
                    table.insert(items, item)
                end
            end
        end
    end

    table.sort(items, function(a, b)
        return a.rel_target < b.rel_target
    end)

    return items
end

--@description: build ordered tree model from items
--@param items FileItem[]
--@return: TreeNode
local function buildTree(items)
    local root = {
        name = ".",
        kind = "dir",
        order = 1,
        rel_path = nil,
        children = {},
        files = {}
    }

    for i, item in ipairs(items) do
        local parts = splitByChar(item.rel_target, "/")
        local node = root
        node.order = math.min(node.order, i)

        for j = 1, (#parts - 1) do
            local seg = parts[j]
            local child = node.children[seg]
            if not child then
                child = {
                    name = seg,
                    kind = "dir",
                    order = i,
                    rel_path = nil,
                    children = {},
                    files = {}
                }
                node.children[seg] = child
            else
                child.order = math.min(child.order, i)
            end
            node = child
        end

        local fname = parts[#parts]
        node.files[fname] = {
            name = fname,
            kind = "file",
            order = i,
            rel_path = item.rel_target,
            children = nil,
            files = nil
        }
    end

    return root
end

--@description: get ordered children list for tree rendering
--@param node TreeNode
--@return: TreeNode[]
local function orderedChildren(node)
    local arr = {}
    if node.children then
        for _, d in pairs(node.children) do
            table.insert(arr, d)
        end
    end
    if node.files then
        for _, f in pairs(node.files) do
            table.insert(arr, f)
        end
    end
    table.sort(arr, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        if a.kind ~= b.kind then
            return a.kind == "dir"
        end
        return a.name < b.name
    end)
    return arr
end

--@description: render ascii tree with file order consistency
--@param root TreeNode
--@return: string
local function renderTree(root)
    local lines = { "." }

    local function visit(node, prefix, is_last)
        local branch = is_last and "`-- " or "|-- "
        local suffix = (node.kind == "dir") and "/" or ""
        table.insert(lines, prefix .. branch .. node.name .. suffix)

        if node.kind == "dir" then
            local next_prefix = prefix .. (is_last and "    " or "|   ")
            local children = orderedChildren(node)
            for idx, child in ipairs(children) do
                visit(child, next_prefix, idx == #children)
            end
        end
    end

    local top = orderedChildren(root)
    for idx, child in ipairs(top) do
        visit(child, "", idx == #top)
    end

    return table.concat(lines, "\n")
end

--@description: render non-yaml output body
--@param items FileItem[]
--@param opt PmcOptions
--@return: string
local function renderStandard(items, opt)
    local out = {}

    local function appendBlock(path_text, content)
        if opt.wrap_mode == "md" then
            table.insert(out, "PATH: " .. path_text)
            table.insert(out, "````")
            table.insert(out, content)
            table.insert(out, "````")
        elseif opt.wrap_mode == "block" then
            table.insert(out, "<<<FILE " .. path_text)
            table.insert(out, content)
            table.insert(out, ">>>END")
        else
            table.insert(out, "PATH: " .. path_text)
            table.insert(out, content)
        end
    end

    for _, item in ipairs(items) do
        appendBlock(item.display_path, item.content)
    end

    return table.concat(out, "\n")
end

--@description: render statistics block
--@param items FileItem[]
--@return: string
local function renderStats(items)
    local total_files = #items
    local total_lines = 0
    local ext_lines = {}

    for _, it in ipairs(items) do
        total_lines = total_lines + it.line_count
        ext_lines[it.ext_key] = (ext_lines[it.ext_key] or 0) + it.line_count
    end

    local keys = {}
    for k, _ in pairs(ext_lines) do
        table.insert(keys, k)
    end
    table.sort(keys)

    local lines = {}
    table.insert(lines, "STATS:")
    table.insert(lines, string.format("  total_files: %d", total_files))
    table.insert(lines, string.format("  total_lines: %d", total_lines))
    table.insert(lines, "  lines_by_suffix:")
    for _, k in ipairs(keys) do
        table.insert(lines, string.format("    %s: %d", k, ext_lines[k]))
    end
    return table.concat(lines, "\n")
end

--@description: yaml quote scalar
--@param s string
--@return: string
local function yamlQuote(s)
    local t = s:gsub("\\", "\\\\"):gsub("\"", "\\\"")
    return "\"" .. t .. "\""
end

--@description: append yaml block scalar content
--@param out string[]
--@param indent string
--@param content string
--@return: nil
local function yamlAppendBlock(out, indent, content)
    if content == "" then
        table.insert(out, indent)
        return
    end
    local c = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    local has_trailing_nl = c:sub(-1) == "\n"
    if has_trailing_nl then
        c = c:sub(1, -2)
    end
    local count = 0
    for line in c:gmatch("([^\n]*)\n?") do
        if line == "" and count > 0 and c:sub(-1) ~= "\n" then
            break
        end
        table.insert(out, indent .. line)
        count = count + 1
    end
    if count == 0 then
        table.insert(out, indent)
    end
end

--@description: render yaml hierarchy from tree and file contents
--@param root TreeNode
--@param items FileItem[]
--@param target_abs string
--@return: string
local function renderYaml(root, items, target_abs)
    local out = {}
    local content_by_rel = {}
    for _, it in ipairs(items) do
        content_by_rel[it.rel_target] = it.content
    end

    table.insert(out, "type: directory")
    table.insert(out, "path: " .. yamlQuote(target_abs))
    table.insert(out, "children:")

    local function renderNodeList(nodes, indent)
        for _, node in ipairs(nodes) do
            if node.kind == "dir" then
                table.insert(out, indent .. "- type: directory")
                table.insert(out, indent .. "  name: " .. yamlQuote(node.name))
                table.insert(out, indent .. "  children:")
                local kids = orderedChildren(node)
                renderNodeList(kids, indent .. "    ")
            else
                local rel = node.rel_path or node.name
                local content = content_by_rel[rel] or ""
                table.insert(out, indent .. "- type: file")
                table.insert(out, indent .. "  path: " .. yamlQuote(rel))
                table.insert(out, indent .. "  content: |-")
                yamlAppendBlock(out, indent .. "    ", content)
            end
        end
    end

    renderNodeList(orderedChildren(root), "  ")
    return table.concat(out, "\n")
end

--@description: write output to file or stdout
--@param text string
--@param output_file string|nil
--@return: nil
local function emitOutput(text, output_file)
    if output_file then
        local f, err = io.open(output_file, "wb")
        if not f then
            fail("cannot open output file: " .. output_file .. " (" .. tostring(err) .. ")")
        end
        f:write(text)
        f:close()
        return
    end
    io.write(text)
    if text:sub(-1) ~= "\n" then
        io.write("\n")
    end
end

--@description: main entry
--@param argv string[]
--@return: nil
local function main(argv)
    local opt = parseArgs(argv)

    if opt.show_help then
        printHelp()
        return
    end

    if opt.show_version then
        io.write(string.format("pmc -- pack-my-code. version %s\n", VERSION))
        return
    end

    local cwd_abs = getCwd()
    local target_abs = getAbsolutePath(opt.target_dir)

    local raw_files
    if opt.ignore_gitignore then
        raw_files = listFilesDirect(target_abs)
    else
        raw_files = listFilesWithGit(target_abs)
    end

    local items = buildFileItems(raw_files, target_abs, opt, cwd_abs)
    local root = buildTree(items)

    if opt.yaml_mode then
        local yaml_text = renderYaml(root, items, target_abs)
        emitOutput(yaml_text, opt.output_file)
        return
    end

    local chunks = {}

    if opt.with_tree then
        table.insert(chunks, renderTree(root))
    end

    table.insert(chunks, renderStandard(items, opt))

    if opt.with_stats then
        table.insert(chunks, renderStats(items))
    end

    local final_text = table.concat(chunks, "\n\n")
    emitOutput(final_text, opt.output_file)
end

main(arg)
