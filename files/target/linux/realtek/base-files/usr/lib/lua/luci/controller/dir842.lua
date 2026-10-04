module("luci.controller.dir842", package.seeall)

function index()
	entry({"admin", "network", "dir842"}, cbi("dir842"), "DIR-842 R1", 90).dependent = false
end
