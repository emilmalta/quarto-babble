-- babble.lua
-- Quarto filter for extracting translatable content and generating language-specific files

local collected = {}
local used_keys = {}
local processed_shortcodes = {}
local reverse_lookup = {}

-- Whitelist of YAML keys that are safe to translate
local translatable_yaml_keys = {
  title = true,
  description = true,
  subtitle = true,
  author = true,
  abstract = true,
  keywords = true,
  summary = true,
  caption = true,
  alt = true,
  label = true,
}

-- Configuration with defaults
local config = {
  languages = {"en"},
  source_lang = "en",
  base_filename = "index"
}

-- Utility functions
local function log_debug(msg)
  -- Enable for debugging
  -- io.stderr:write("DEBUG: " .. msg .. "\n")
end

-- Slugify: convert text to valid YAML key
local function slugify(str)
  if not str or str == "" then return "text" end
  local result = str
    :lower()
    :gsub("[^%w]", "_")
    :gsub("_+", "_")
    :gsub("^_+", "")
    :gsub("_+$", "")
  
  if result == "" then result = "text" end
  if #result > 50 then result = result:sub(1, 40):gsub("_+$", "") end
  
  return result
end

-- Ensure key uniqueness
local function ensure_unique_key(base)
  if not base or base == "" then base = "text" end
  local key = base
  local counter = 1
  while collected[key] do
    counter = counter + 1
    key = base .. "_" .. counter
  end
  return key
end

-- Store text with deduplication
local function store_text(text, context)
  if not text or text == "" or not text:match("%w") then return nil end
  
  -- Return existing key if text already seen
  if reverse_lookup[text] then return reverse_lookup[text] end
  
  local slug = slugify(text)
  if slug == "" then slug = "text" end
  
  local base = context .. "_" .. slug
  local key = ensure_unique_key(base)
  
  collected[key] = text
  reverse_lookup[text] = key
  log_debug("Stored: " .. key .. " = " .. text)
  return key
end

-- Mark key as used
local function mark_key_used(key)
  if key then used_keys[key] = true end
end

-- YAML escaping
local function escape_yaml_value(str)
  if not str then return '""' end
  str = str:gsub("\\", "\\\\"):gsub('"', '\\"')
  if str:match("^%s") or str:match("%s$") or str:match("[:{}%[%]|>]") or str:match("^[%-%?:,@&*!`'\"]") then
    return '"' .. str .. '"'
  end
  return '"' .. str .. '"'
end

-- Process shortcode attributes
local function process_shortcode_attributes(text, shortcode_type)
  local attributes = {}
  local modified = false
  
  -- Handle single-quoted values (keep as-is for R expressions)
  for key, val in text:gmatch("(%w+)%s*=%s*'([^']+)'") do
    table.insert(attributes, {key = key, val = val, quote = "'"})
  end
  
  -- Handle double-quoted values
  for key, val in text:gmatch('(%w+)%s*=%s*"([^"]+)"') do
    -- Skip if already processed or is an expression
    if not val:match("^`r") and not val:match("^t:") then
      local keyname = shortcode_type .. "_" .. slugify(val)
      keyname = ensure_unique_key(keyname)
      collected[keyname] = val
      mark_key_used(keyname)
      val = "t:" .. keyname
      modified = true
    end
    table.insert(attributes, {key = key, val = val, quote = '"'})
  end
  
  if not modified then return text end
  
  -- Format shortcode with aligned keys
  local max_key_len = 0
  for _, attr in ipairs(attributes) do
    max_key_len = math.max(max_key_len, #attr.key)
  end
  
  local lines = {"{{< " .. shortcode_type}
  for _, attr in ipairs(attributes) do
    local padding = string.rep(" ", max_key_len - #attr.key)
    local quote = attr.quote or '"'
    table.insert(lines, "  " .. attr.key .. padding .. " = " .. quote .. attr.val .. quote)
  end
  table.insert(lines, ">}}")
  
  return table.concat(lines, "\n")
end

-- AST processing functions
function Header(el)
  local text = pandoc.utils.stringify(el.content)
  local key = store_text(text, "header")
  if key then mark_key_used(key) end
  return el
end

function Para(el)
  local text = pandoc.utils.stringify(el.content)
  if text:match("%w") then
    local key = store_text(text, "para")
    if key then mark_key_used(key) end
  end
end

function BlockQuote(el)
  local text = pandoc.utils.stringify(el.content)
  if text:match("%w") then
    local key = store_text(text, "quote")
    if key then mark_key_used(key) end
  end
end

function RawBlock(el)
  if el.format == "markdown" and el.text:match("^{{<%s*[%w%-_]+") then
    local shortcode_type = el.text:match("^{{<%s*([%w%-_]+)")
    if shortcode_type and not processed_shortcodes[el.text] then
      processed_shortcodes[el.text] = true
      return pandoc.RawBlock("markdown", process_shortcode_attributes(el.text, shortcode_type))
    end
  end
end

-- Process YAML frontmatter line
local function process_yaml_line(line, current_key)
  if line:match("^%s*$") or line:match("^%s*#") then return line end
  
  -- Handle YAML list items
  if line:match("^%s+%-%s+\"[^\"]+\"") and translatable_yaml_keys[current_key] then
    local indent, quoted_text = line:match("^(%s+)%-%s+\"([^\"]+)\"")
    if quoted_text and quoted_text:match("%w") then
      local key = store_text(quoted_text, "meta")
      if key then
        mark_key_used(key)
        return indent .. '- {{< meta langstrings.' .. key .. ' >}}'
      end
    end
  end
  
  -- Handle key-value pairs
  local key, value = line:match("^([%w_%-]+):%s*(.*)$")
  if key and value and value ~= "" then
    local clean_value = value:gsub('^"', ''):gsub('"$', ''):gsub("^'", ""):gsub("'$", "")
    if translatable_yaml_keys[key] and clean_value:match("%w") then
      local text_key = store_text(clean_value, "meta")
      if text_key then
        mark_key_used(text_key)
        return key .. ': "{{< meta langstrings.' .. text_key .. ' >}}"'
      end
    end
  end
  
  return line
end

-- Process content line
local function process_content_line(line, in_code_block)
  if in_code_block then return line end
  
  -- Skip lines with existing meta langstrings
  if line:match("{{<%s*meta%s+langstrings%.") then
    for key in line:gmatch("{{<%s*meta%s+langstrings%.([%w_]+)%s*>}}") do
      mark_key_used(key)
    end
    return line
  end
  
  -- Handle headers
  local prefix, text = line:match("^(#+%s+)(.+)$")
  if prefix and text and text:match("%w") then
    local key = store_text(text, "header")
    if key then
      mark_key_used(key)
      return prefix .. "{{< meta langstrings." .. key .. " >}}"
    end
  end
  
  -- Handle shortcodes
  if line:match("^{{<%s*[%w%-_]+") then
    local shortcode = line:match("^{{<%s*([%w%-_]+)")
    if shortcode and not processed_shortcodes[line] then
      processed_shortcodes[line] = true
      return process_shortcode_attributes(line, shortcode)
    end
  end
  
  -- Handle paragraph text
  if line:match("%w") and
     not line:match("^#") and
     not line:match("^```") and
     not line:match("^{{<") and
     not line:match("^::") and
     not line:match("^%s*$") and
     not line:match("^[%w_%-]+:%s*") then
    local key = store_text(line, "para")
    if key then
      mark_key_used(key)
      return "{{< meta langstrings." .. key .. " >}}"
    end
  end
  
  return line
end

-- Write output files
local function write_outputs()
  local infile = quarto.doc.input_file or "index.qmd"
  config.base_filename = infile:match("([^/\\]+)%.%w+$") or infile:match("([^/\\]+)$") or "index"
  if config.base_filename:match("%.") then
    config.base_filename = config.base_filename:gsub("%..*$", "")
  end
  
  local input = io.open(infile, "r")
  if not input then
    io.stderr:write("ERROR: Cannot open input file: " .. infile .. "\n")
    return
  end
  
  local lines = {}
  local in_code_block = false
  local in_yaml_frontmatter = false
  local current_yaml_key = nil
  local in_shortcode = false
  local shortcode_lines = {}
  
  for line in input:lines() do
    if line:match("^---$") then
      in_yaml_frontmatter = not in_yaml_frontmatter
      table.insert(lines, line)
    elseif in_yaml_frontmatter then
      local yaml_key = line:match("^([%w_%-]+):")
      if yaml_key then current_yaml_key = yaml_key end
      table.insert(lines, process_yaml_line(line, current_yaml_key))
    else
      if line:match("^```") then in_code_block = not in_code_block end
      
      -- Handle multiline shortcodes
      if line:match("^{{<%s*[%w%-_]+") and not line:match(">}}%s*$") then
        in_shortcode = true
        shortcode_lines = {line}
      elseif in_shortcode then
        table.insert(shortcode_lines, line)
        if line:match(">}}%s*$") then
          in_shortcode = false
          local combined = table.concat(shortcode_lines, "\n")
          local shortcode_type = combined:match("^{{<%s*([%w%-_]+)")
          if shortcode_type and not processed_shortcodes[combined] then
            processed_shortcodes[combined] = true
            table.insert(lines, process_shortcode_attributes(combined, shortcode_type))
          else
            table.insert(lines, combined)
          end
          shortcode_lines = {}
        end
      else
        local processed_line = process_content_line(line, in_code_block)
        table.insert(lines, processed_line)
        
        -- Track used keys
        for key in processed_line:gmatch("{{<%s*meta%s+langstrings%.([%w_]+)%s*>}}") do
          mark_key_used(key)
        end
        for key in processed_line:gmatch('"t:([%w_]+)"') do
          mark_key_used(key)
        end
      end
    end
  end
  
  input:close()
  
  -- Get sorted keys
  local sorted_keys = {}
  for key in pairs(collected) do
    if used_keys[key] then table.insert(sorted_keys, key) end
  end
  table.sort(sorted_keys)
  
  -- Write language files
  for _, lang in ipairs(config.languages) do
    local out_file_path = config.base_filename .. "." .. lang .. ".qmd"
    local out_file = io.open(out_file_path, "w")
    if not out_file then
      io.stderr:write("ERROR: Cannot create file: " .. out_file_path .. "\n")
    else
      local output_lines = {}
      local in_frontmatter = false
      local lang_updated = false
      local langstrings_added = false
      local frontmatter_lines = {}
      
      for _, line in ipairs(lines) do
        if line:match("^---$") then
          if not in_frontmatter then
            in_frontmatter = true
            table.insert(frontmatter_lines, line)
          else
            in_frontmatter = false
            
            -- Process frontmatter and skip babble config
            local in_babble_section = false
            for _, fm_line in ipairs(frontmatter_lines) do
              -- Skip the entire babble configuration section
              if fm_line:match("^babble:") then
                in_babble_section = true
                -- Don't add this line to output
              elseif in_babble_section and fm_line:match("^%s+") then
                -- Skip indented lines within babble section
                -- Don't add these lines to output
              elseif in_babble_section and not fm_line:match("^%s+") then
                -- We've hit a non-indented line, babble section is over
                in_babble_section = false
                -- Process this line normally since it's not part of babble
                if fm_line:match("^lang:%s*") then
                  table.insert(output_lines, "lang: " .. lang)
                  lang_updated = true
                else
                  table.insert(output_lines, fm_line)
                end
              elseif not in_babble_section then
                -- Normal processing - we're not in babble section
                if fm_line:match("^lang:%s*") then
                  table.insert(output_lines, "lang: " .. lang)
                  lang_updated = true
                else
                  table.insert(output_lines, fm_line)
                end
              end
              -- Note: if we're in_babble_section and it's the babble: line or indented, we add nothing
            end
            
            -- Add draft: true for non-source languages (before langstrings)
            if lang ~= config.source_lang then
              table.insert(output_lines, "draft: true")
              log_debug("Added draft: true for " .. lang .. " (source is " .. config.source_lang .. ")")
            else
              log_debug("Skipped draft for source language: " .. lang)
            end
            
            -- Add langstrings
            if not langstrings_added then
              table.insert(output_lines, "langstrings:")
              for _, key in ipairs(sorted_keys) do
                local value = collected[key]
                if lang == config.source_lang then
                  table.insert(output_lines, "  " .. key .. ": " .. escape_yaml_value(value))
                else
                  table.insert(output_lines, "  " .. key .. ': "" # ' .. value)
                end
              end
              langstrings_added = true
            end
            
            table.insert(output_lines, line)
          end
        elseif in_frontmatter then
          table.insert(frontmatter_lines, line)
        else
          table.insert(output_lines, line)
        end
      end
      
      -- Add lang if missing
      if not lang_updated then
        local new_lines = {}
        local added_lang = false
        for _, line in ipairs(output_lines) do
          if line:match("^---$") and not added_lang then
            table.insert(new_lines, line)
            table.insert(new_lines, "lang: " .. lang)
            added_lang = true
          else
            table.insert(new_lines, line)
          end
        end
        output_lines = new_lines
      end
      
      out_file:write(table.concat(output_lines, "\n"))
      out_file:close()
      log_debug("Created " .. out_file_path)
    end
  end
end

-- Main entry point
function Pandoc(doc)
  local meta = doc.meta
  
  -- Check if langstrings already exist - if so, just render normally
  if meta.langstrings then
    log_debug("Found existing langstrings - rendering mode")
    return doc
  end
  
  -- No langstrings found - enter extraction mode
  log_debug("No langstrings found - extraction mode")
  
  -- Extract configuration from metadata
  if meta.babble and meta.babble.languages then
    config.languages = {}
    local languages = meta.babble.languages
    
    if type(languages) == "table" and languages.t == "MetaList" then
      for _, lang in ipairs(languages) do
        table.insert(config.languages, pandoc.utils.stringify(lang))
      end
    elseif type(languages) == "table" and #languages > 0 then
      for _, lang in ipairs(languages) do
        table.insert(config.languages, pandoc.utils.stringify(lang))
      end
    else
      table.insert(config.languages, pandoc.utils.stringify(languages))
    end
    
    log_debug("Configured languages: " .. table.concat(config.languages, ", "))
  else
    log_debug("No babble.languages found, using default: " .. table.concat(config.languages, ", "))
  end
  
  -- Get source language
  if meta.lang then
    config.source_lang = pandoc.utils.stringify(meta.lang)
  end
  
  -- Process metadata fields
  local function process_meta_field(field, prefix)
    if meta[field] then
      local val = pandoc.utils.stringify(meta[field])
      if val and val ~= "" then
        local key = store_text(val, prefix)
        if key then mark_key_used(key) end
      end
    end
  end
  
  process_meta_field("title", "meta")
  process_meta_field("description", "meta")
  
  write_outputs()
  return doc
end