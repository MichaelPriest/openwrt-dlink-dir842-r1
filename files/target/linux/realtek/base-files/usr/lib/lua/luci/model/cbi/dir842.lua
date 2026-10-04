local sys = require "luci.sys"

m = Map("dir842", "DIR-842 R1",
	"Painel específico do hardware. O modo AP transforma a porta WAN física em mais uma porta LAN, desativa DHCP/NAT local e recebe o IP de gerenciamento do roteador principal.")

s = m:section(NamedSection, "asic", "asic", "Modo operacional")
s.addremove = false

role = s:option(ListValue, "role", "Modo")
role:value("router", "Roteador")
role:value("bridge", "Ponto de acesso (AP / bridge)")
role.rmempty = false

function role.cfgvalue(self, section)
	return m.uci:get("dir842", "asic", "role") or "router"
end

function role.write(self, section, value)
	if value ~= "bridge" then
		value = "router"
	end

	local rc = sys.call("/bin/sh /usr/sbin/dir842-mode " .. value .. " >/tmp/dir842-mode.log 2>&1")
	if rc == 0 then
		sys.call("touch /tmp/dir842-mode-changed")
	else
		error("Falha ao preparar o novo modo. Veja /tmp/dir842-mode.log.")
	end
end

note = s:option(DummyValue, "_warning", "Importante")
note.rawhtml = true
function note.cfgvalue()
	return "<strong>Ao salvar esta página, o roteador reinicia.</strong> Em modo AP, o endereço 192.168.0.1 deixa de ser usado e o DIR-842 recebe um novo IP por DHCP do roteador principal."
end

status = m:section(SimpleSection, nil, "Estado atual")

active = status:option(DummyValue, "_role", "Função ASIC")
function active.cfgvalue()
	return m.uci:get("dir842", "asic", "role") or "automático (roteador com a configuração padrão)"
end

hwnat = status:option(DummyValue, "_hwnat", "Hardware NAT")
function hwnat.cfgvalue()
	local v = sys.exec("cat /sys/module/rtl819x/parameters/hwnat 2>/dev/null"):gsub("%s+", "")
	if v == "Y" then return "Ativado" end
	if v == "N" then return "Desativado" end
	return "Indisponível"
end

local ports = {
	{ 0, "LAN 1" },
	{ 1, "LAN 2" },
	{ 2, "LAN 3" },
	{ 3, "LAN 4" },
	{ 4, "WAN física" },
	{ 6, "CPU / trunk" }
}

for _, item in ipairs(ports) do
	local p = item[1]
	local label = item[2]
	local o = status:option(DummyValue, "_port" .. p, label)
	function o.cfgvalue()
		local v = sys.exec("swconfig dev switch0 port " .. p .. " get link 2>/dev/null")
		v = v:gsub("^%s+", ""):gsub("%s+$", "")
		if v == "" then return "Indisponível" end
		v = v:gsub("port:" .. p .. "%s+", "")
		v = v:gsub("link:up", "conectada")
		v = v:gsub("link:down", "desconectada")
		v = v:gsub("speed:", "")
		v = v:gsub("full%-duplex", "full-duplex")
		return v
	end
end

function m.on_after_commit(self)
	if sys.call("test -e /tmp/dir842-mode-changed") == 0 then
		sys.call("rm -f /tmp/dir842-mode-changed; (sleep 4; reboot) >/dev/null 2>&1 &")
	end
end

return m
