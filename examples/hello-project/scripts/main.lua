-- HelloProject gameplay script.
-- The Lua VM and gameplay scripting API are planned subsystems; this file is a
-- placeholder demonstrating where project scripts live.

local function on_start()
    print("Hello from CoreXEngine!")
end

return {
    on_start = on_start,
}
