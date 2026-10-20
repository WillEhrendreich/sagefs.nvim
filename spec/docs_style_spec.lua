-- The docs hold to the writing rules, because a rule nobody checks is a rule nobody follows.
--
-- The rule is in the SageFs repo's AGENTS.md under "Writing: no slop", and the catalogue behind
-- it is the `plain-english` skill. The shapes with no legitimate use are ratcheted here; a word
-- with a legitimate use ("ecosystem", "leverage") is not, because the catalogue treats those as
-- a review list and a ratchet that flagged them would fail on good prose.
--
-- The exceptions matter as much as the patterns. A dash between two digits is a range, a dash
-- inside quotes is material the plugin really prints, and a dash in a code block is a sample a
-- reader may copy.
local function read_file(path)
  local handle = io.open(path, "r")
  if not handle then return nil end
  local text = handle:read("*a")
  handle:close()
  return text
end

-- The files that ship, read from the git index so an untracked note is never ratcheted.
local function tracked_markdown()
  local pipe = io.popen("git ls-files '*.md'")
  if not pipe then return {} end
  local files = {}
  for line in pipe:lines() do
    if line ~= "" and not line:match("/node_modules/") and not line:match("/obj/") and not line:match("/bin/") then
      files[#files + 1] = line
    end
  end
  pipe:close()
  return files
end

-- The spans of a line inside double quotes.
local function quoted_spans(line)
  local spans = {}
  local inside = false
  local start = 0
  for i = 1, #line do
    if line:sub(i, i) == '"' then
      if inside then
        spans[#spans + 1] = { start, i }
        inside = false
      else
        inside = true
        start = i + 1
      end
    end
  end
  if inside then spans[#spans + 1] = { start, #line } end
  return spans
end

local function in_quoted(spans, index)
  for _, span in ipairs(spans) do
    if index >= span[1] and index <= span[2] then return true end
  end
  return false
end

-- The shapes, by name.
--
-- A Lua pattern has no alternation: `|` is a literal character there, so a shape that can be
-- spelled several ways is one entry per spelling.
local shapes = {
  { "a negation frame", "not%s+just%s+[^%.,;]+[,;]%s*it'?s" },
  { "a negation frame", "not%s+just%s+[^%.,;]+[,;]%s*but" },
  { "a tailing negation", "%f[%w]no%s+[%a]+%s*,%s*just%s+[%a]+" },
  { "a staged opener", "In today'?s fast%-paced world" },
  { "a staged opener", "In an era of" },
  { "a staged opener", "In a world where" },
  { "a staged opener", "Ever wondered" },
  { "a staged opener", "Have you ever" },
  { "a staged opener", "What if I told you" },
  { "a staged opener", "Did you know" },
  { "a staged opener", "Picture this" },
  { "a staged opener", "Imagine a world where" },
  { "a staged opener", "Let'?s dive in" },
  { "a staged emphasis", "the key takeaway" },
  { "a staged emphasis", "the real question is" },
  { "a staged emphasis", "at its core" },
  { "a staged emphasis", "fundamentally speaking" },
  { "a staged emphasis", "the truth is" },
  { "a staged emphasis", "in reality" },
  { "a staged emphasis", "the heart of the matter" },
  { "a staged emphasis", "let that sink in" },
  { "a staged emphasis", "read that again" },
  { "a staged emphasis", "it'?s important to note" },
  { "a staged emphasis", "it'?s worth noting" },
  { "a closing beat", "[Ii]n conclusion" },
  { "a closing beat", "[Ii]n summary" },
  { "a closing beat", "[Tt]o sum up" },
  { "a closing beat", "All in all" },
  { "a closing beat", "Hope this helps" },
  { "a closing beat", "Feel free to reach out" },
  { "a closing beat", "Let me know if you'?d like" },
  { "a weasel attribution", "[Ee]xperts? agree" },
  { "a weasel attribution", "[Ss]tudies show" },
  { "a weasel attribution", "[Rr]esearch suggests" },
  { "a weasel attribution", "[Ss]cientists believe" },
  { "a fake-insight tail", ",%s*highlighting" },
  { "a fake-insight tail", ",%s*reflecting" },
  { "a fake-insight tail", ",%s*underscoring" },
  { "a fake-insight tail", ",%s*showcasing" },
  { "a fake-insight tail", ",%s*paving the way for" },
  { "a fake-insight tail", ",%s*raising questions about" },
  { "a fake-insight tail", ",%s*sparking debate" },
  { "a transition crutch", "[Mm]oreover" },
  { "a transition crutch", "[Ff]urthermore" },
  { "a transition crutch", "[Aa]dditionally" },
  { "a transition crutch", "[Cc]onsequently" },
  { "a transition crutch", "[Nn]evertheless" },
  { "a transition crutch", "[Nn]onetheless" },
  { "a transition crutch", "[Nn]otably" },
  { "a transition crutch", "[Uu]ltimately" },
  { "filler grammar", "in order to" },
  { "filler grammar", "has the ability to" },
  { "filler grammar", "a large number of" },
  { "filler grammar", "on a regular basis" },
  { "filler grammar", "with regard to" },
  { "template residue", "%[Your Name%]" },
  { "template residue", "%[TODO%]" },
  { "template residue", "%[insert " },
}

-- The em dashes in a line that are prose.
--
-- Lua strings are byte strings, so the dash is found with a PLAIN find: a pattern's character
-- class would match one byte of the three-byte sequence and never see the dash at all.
local function prose_dashes(line)
  local quotes = quoted_spans(line)
  local count = 0
  local index = 1
  while true do
    local start, stop = line:find("—", index, true)
    if not start then
      start, stop = line:find("–", index, true)
    end
    if not start then break end
    local before = line:sub(start - 1, start - 1)
    local after = line:sub(stop + 1, stop + 1)
    local is_range = before:match("%d") ~= nil and after:match("%d") ~= nil
    if not is_range and not in_quoted(quotes, start) then count = count + 1 end
    index = stop + 1
  end
  return count
end

-- The lines of a file that are prose: no code fence, no inline code, and not the block that
-- names the shapes.
local function prose_lines(text)
  local lines = {}
  local in_fence = false
  local in_rule = false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif in_fence then
      -- a code block is not prose
    else
      if in_rule and line:match("^%s*#") then in_rule = false end
      if line:gsub("^#+%s*", "") == "Writing: no slop" then in_rule = true end
      if in_rule then
        -- the block that names the shapes may name them
      else
        -- inline code is a sample or an identifier, not prose
        local stripped = line:gsub("`[^`]*`", "")
        lines[#lines + 1] = stripped
      end
    end
  end
  return lines
end

describe("documentation style", function()
  it("holds to the writing rules", function()
    local findings = {}
    for _, file in ipairs(tracked_markdown()) do
      local text = read_file(file)
      if text then
        local lines = prose_lines(text)
        for index, line in ipairs(lines) do
          for _, shape in ipairs(shapes) do
            if line:match(shape[2]) then
              findings[#findings + 1] = string.format("%s:%d  [%s]  %s", file, index, shape[1], (line:gsub("^%s+", "")))
            end
          end
          local dashes = prose_dashes(line)
          if dashes > 0 then
            findings[#findings + 1] = string.format("%s:%d  [%d em dash(es)]  %s", file, index, dashes, (line:gsub("^%s+", "")))
          end
        end
      end
    end
    assert.are.equal(0, #findings, "the docs carry " .. #findings .. " banned shape(s):\n" .. table.concat(findings, "\n"))
  end)
end)
