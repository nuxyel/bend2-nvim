vim.filetype.add({ extension = { bend = "bend" } })

vim.api.nvim_create_user_command("Bend2Setup", function()
  require("bend2").setup()
end, { desc = "Initialize Bend 2 support" })
