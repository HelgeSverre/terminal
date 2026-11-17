-- Isolated external-client configuration, not a user configuration change.
-- Apply helge-terminal.patch to the pinned clone before opening an image.
local checkout = assert(vim.env.HELGE_SNACKS_CHECKOUT, "set HELGE_SNACKS_CHECKOUT to the patched Snacks clone")
vim.opt.runtimepath:append(checkout)
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.shortmess:append("I")

for _, name in ipairs({ "KITTY", "GHOSTTY", "WEZTERM", "HELGE" }) do
  assert(vim.env["SNACKS_" .. name] == nil, "unset SNACKS_" .. name .. " for default-detection validation")
end

require("snacks").setup({
  image = { enabled = true, force = false, doc = { enabled = false } },
})

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local terminal = require("snacks.image.terminal")
    terminal.detect(function(identity)
      local environment = terminal.env()
      local result = {
        identity = identity.terminal,
        version = identity.version,
        environment = environment.name,
        supported = environment.supported == true,
        placeholders = environment.placeholders == true,
        image_buffer = vim.bo.filetype == "image",
      }
      result.passed = result.supported and result.placeholders
        and result.environment:find("helge", 1, true) ~= nil and result.image_buffer
      vim.g.helge_snacks_result = result
      if vim.env.HELGE_SNACKS_REPORT then
        vim.fn.writefile({ vim.json.encode(result) }, vim.env.HELGE_SNACKS_REPORT)
      end
      vim.notify(vim.inspect(result), result.passed and vim.log.levels.INFO or vim.log.levels.ERROR)
    end)
  end,
})
