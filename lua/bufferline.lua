local vim = _G.vim
local api = vim.api
local highlight = '%#BufferLine#'
local inactive_highlight = '%#BufferLineInactive#'
local tab_highlight = '%#BufferLineTab#'
local tab_selected_highlight = '%#BufferLineTabSelected#'
local suffix_highlight = '%#BufferLineTabSelected#'
local selected_highlight = '%#BufferLineSelected#'
local diagnostic_highlight = '%#ErrorMsg#'
local background = '%#BufferLineBackground#'
local close = '%#BufferLine#%999X'
local padding = " "

---------------------------------------------------------------------------//
-- EXPORT
---------------------------------------------------------------------------//

local M = {}

---------------------------------------------------------------------------//
-- HELPERS
---------------------------------------------------------------------------//

local function safely_get_var(var)
  if pcall(function() api.nvim_get_var(var) end) then
    return api.nvim_get_var(var)
  else
    return nil
  end
end

local function contains(table, element)
  for key, _ in pairs(table) do
    if key == element then
      return true
    end
  end
  return false
end

local function table_size(t)
  local count = 0
  for _ in pairs(t) do count = count + 1 end
  return count
end

-- Source: https://teukka.tech/luanvim.html
local function nvim_create_augroups(definitions)
  for group_name, definition in pairs(definitions) do
    api.nvim_command('augroup '..group_name)
    api.nvim_command('autocmd!')
    for _,def in pairs(definition) do
      local command = table.concat(vim.tbl_flatten{'autocmd', def}, ' ')
      api.nvim_command(command)
    end
    api.nvim_command('augroup END')
  end
end

local function _get_hex(hl_name, part)
  local id = api.nvim_call_function('hlID', {hl_name})
  return api.nvim_call_function('synIDattr', {id, part})
end

local function set_highlight(name, user_var)
  local dict = safely_get_var(user_var)
  if dict ~= nil and table_size(dict) > 0 then
    local cmd = "highlight! "..name
    if contains(dict, "gui") then
      cmd = cmd.." ".."gui="..dict.gui
    end
    if contains(dict, "guifg") then
      cmd = cmd.." ".."guifg="..dict.guifg
    end
    if contains(dict, "guibg") then
      cmd = cmd.." ".."guibg="..dict.guibg
    end
    if not pcall(api.nvim_command, cmd) then
      api.nvim_err_writeln(
        "Unable to set your highlights, something isn't configured correctly"
        )
    end
  end
end

local function make_clickable(item, buf_num)
  local is_clickable = api.nvim_call_function('has', {'tablineat'})
  if is_clickable then
    -- TODO: can the arbitrary function we pass be a lua func, if so HOW...
    return "%"..buf_num.."@nvim_bufferline#handle_click@"..item
  else
    return item
  end
end

---------------------------------------------------------------------------//
-- CORE
---------------------------------------------------------------------------//
function M.handle_click(id)
  if id ~= nil then
    api.nvim_command('buffer '..id)
  end
end

-- Borrowed this trick from
-- https://github.com/bagrat/vim-buffet/blob/28e8535766f1a48e6006dc70178985de2b8c026d/autoload/buffet.vim#L186
-- If the current buffer in the current window has a matching ID it is ours and so should
-- have the main selected highlighting. If it isn't but it is the window highlight it as inactive
-- the "trick" here is that "bufwinnr" retunrs a value which is the first window associated with a buffer
-- if there are no windows associated i.e. it is not in view and the function returns -1
local function get_buffer_highlight(buf_id)
  local current = api.nvim_call_function('winbufnr', {0}) == buf_id
  if current then
    return selected_highlight
  elseif api.nvim_call_function('bufwinnr', {buf_id}) > 0 then
    return inactive_highlight
  else
    return highlight
  end
end

local function create_buffer(path, buf_num, diagnostic_count)
  local buf_highlight = get_buffer_highlight(buf_num)
  local length

  if path == "" then
    path = "[No Name]"
  elseif string.find(path, 'term://') ~= nil then
    local name = api.nvim_call_function('fnamemodify', {path, ":p:t"})
    name = padding..' '..name..padding
    length = string.len(name)
    return buf_highlight..name, length
  end

  local modified = api.nvim_buf_get_option(buf_num, 'modified')
  local file_name = api.nvim_call_function('fnamemodify', {path, ":p:t"})
  local devicons_loaded = api.nvim_call_function('exists', {'*WebDevIconsGetFileTypeSymbol'})

  -- parameters for devicons func: (filename), (isDirectory)
  local icon = devicons_loaded and api.nvim_call_function('WebDevIconsGetFileTypeSymbol', {path}) or ""
  local buffer = padding..icon..padding..file_name..padding
  -- Avoid including highlight strings in the buffer length
  length = string.len(buffer)
  buffer = buf_highlight..make_clickable(buffer, buf_num)

  if diagnostic_count > 0 then
    local diagnostic_section = diagnostic_count..padding
    length = length + string.len(diagnostic_section)
    buffer = buffer..diagnostic_highlight..diagnostic_section
  end

  if modified then
    local modified_icon = safely_get_var("bufferline_modified_icon")
    modified_icon = modified_icon ~= nil and modified_icon or "●"
    local modified_section = modified_icon..padding
    length = length + string.len(modified_section)
    buffer = buffer..modified_section
  end

  return buffer .."%X", length
end

local function tab_click_component(num)
  return "%"..num.."T"
end

local function create_tab(num, is_active)
  local hl = is_active and tab_selected_highlight or tab_highlight
  local name = padding.. num ..padding
  local length = string.len(name)
  return hl .. tab_click_component(num) .. name .. "%X", length
end

local function get_tabs()
  local all_tabs = {}
  local tabs = api.nvim_list_tabpages()
  local current_tab = api.nvim_get_current_tabpage()

  for _,tab in ipairs(tabs) do
    local is_active_tab = current_tab == tab
    local component, length = create_tab(tab, is_active_tab)
    all_tabs[tab] = {component = component, length = length}
  end
  return all_tabs
end

local function get_close_component()
  local close_icon = safely_get_var("bufferline_close_icon")
  close_icon = close_icon ~= nil and close_icon or " close "
  return close_icon, string.len(close_icon)
end

-- The provided api nvim_is_buf_loaded filters out all hidden buffers
local function is_valid(buffer)
  local listed = api.nvim_buf_get_option(buffer, "buflisted")
  local exists = api.nvim_buf_is_valid(buffer)
  return listed and exists
end

-- PREREQUISITE: active buffer always remains in view
-- 1. Find amount of available space in the window
-- 2. Find the amount of space the bufferline will take up
-- 3. If the bufferline will be too long truncate it by one buffer
-- 4. Re-check the size
-- 5. If still too long truncate recursively till it fits
-- 6. Add the number of truncated buffers as an indicator
local function truncate_if_needed(buffers, tabs, close_length)
  local line = ""
  local suffix = ""
  local omitted = 0
  local available_width = api.nvim_get_option("columns")
  local total_length = close_length

  -- Add the length of the tabs + close components to total length
  for _,t in pairs(tabs) do
    if t.length ~= nil and t.component ~= nil then
      total_length = total_length + t.length
      line = line .. t.component
    end
  end

  for _,v in pairs(buffers) do
    if available_width >= total_length + v.length then
      total_length = total_length + v.length
      line = line .. v.component
    else
      omitted = omitted + 1
      suffix = padding.."+"..omitted..padding
    end
  end
  return line..suffix_highlight..suffix
end

-- TODO
-- [X] Show tabs
-- [ ] Buffer label truncation
-- [ ] Handle keeping active buffer always in view
-- [ ] Highlight file type icons if possible
-- [X] Fix current buffer highlight disappearing when inside ignored buffer
function M.bufferline()
  local buf_nums = api.nvim_list_bufs()
  local buffers = {}
  local tabs = get_tabs()

  for _,buf_id in ipairs(buf_nums) do
    if is_valid(buf_id) then
      local name =  api.nvim_buf_get_name(buf_id)
      local buf, length = create_buffer(name, buf_id, 0)
      local is_current = api.nvim_call_function('winbufnr', {0}) == buf_id
      buffers[buf_id] = {
        component = buf,
        length = length,
        current = is_current
      }
    end
  end

  local close_component, close_length = get_close_component()
  local buffer_line = truncate_if_needed(buffers, tabs, close_length)

  buffer_line = buffer_line..background
  buffer_line = buffer_line..padding
  buffer_line = buffer_line.."%="..close..close_component
  return buffer_line
end

-- TODO pass the preferences through on setup to go into the colors function
-- this way we can setup config vars in lua e.g.
-- lua require('bufferline').setup({
--  highlight = {
--     inactive_highlight: '#mycolor'
--  }
--})
function M.setup()
  function _G.setup_bufferline_colors()
    set_highlight('TabLineFill','bufferline_background')
    set_highlight('BufferLine', 'bufferline_buffer')
    set_highlight('BufferLineInactive', 'bufferline_buffer_inactive')
    set_highlight('BufferLineBackground','bufferline_buffer')
    set_highlight('BufferLineSelected','bufferline_selected')
    set_highlight('BufferLineTab', 'bufferline_tab')
    set_highlight('BufferLineTabSelected', 'bufferline_tab_selected')
  end
  nvim_create_augroups({
      BufferlineColors = {
        {"VimEnter", "*", [[lua setup_bufferline_colors()]]};
        {"ColorScheme", "*", [[lua setup_bufferline_colors()]]};
      }
    })
  api.nvim_set_option("showtabline", 2)
  api.nvim_set_option("tabline", [[%!luaeval("require'bufferline'.bufferline()")]])
end

return M