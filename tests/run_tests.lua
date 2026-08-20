local function assert_no_string_method_syntax(path)
    local file = assert(io.open(path, "r"))
    local source = file:read("*a")
    file:close()
    local unsupported_methods = {
        ":gsub(", ":match(", ":lines(", ":read(", ":write(", ":close("
    }
    for _, method in ipairs(unsupported_methods) do
        assert(not string.find(source, method, 1, true),
            path .. " uses method syntax unsupported by EdgeTX Lua: " .. method)
    end
end

assert_no_string_method_syntax("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
assert_no_string_method_syntax("SDCARD/WIDGETS/NERC_GSkyFD/main.lua")
assert_no_string_method_syntax("SDCARD/SCRIPTS/TOOLS/GooskySetup.lua")

dofile("tests/mock_edgetx.lua")
dofile("tests/mock_goosky_setup.lua")
