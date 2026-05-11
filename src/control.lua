---------------------------------------------------------------------------------------------------
--- Design rules:
--- * `KuxCoreLib.Events` should be uses instead `script`
--- * there must be no global functions -> WIP
---------------------------------------------------------------------------------------------------

---@class Control
Control = {}

---@class Control.private : Control
local this = {}
---------------------------------------------------------------------------------------------------
require("mod")
if script.active_mods["gvv"] then require("__gvv__.gvv")() end
Version = KuxCoreLib.Version.asGlobal()
Events = KuxCoreLib.Events.asGlobal()
-- require("__Kux-CoreLib__/stdlib/core")
Area = require("__Kux-CoreLib__/stdlib/area/area") -- preload required by Position
Chunk = require("__Kux-CoreLib__/stdlib/area/chunk")
Position = require("__Kux-CoreLib__/stdlib/area/position")

require "modules/tools"
require "modules/autotargeter"
require "modules/gui"
require "modules/Permissions"
require "modules/IonCannonStorage"
require "modules/targeter"
require "modules/interface"
require "modules/IonCannon"
---------------------------------------------------------------------------------------------------

local fLog = function (functionName) print("control."..functionName) end

setmetatable(this, {__index = Control})

_G.when_ion_cannon_targeted = nil


function this.register_se_events_init()
	if remote.interfaces["space-exploration"] then
		local se_rocket_event = remote.call("space-exploration", "get_on_cargo_rocket_launched_event")
		if se_rocket_event then
			storage.se_cargo_rocket_event_id = se_rocket_event
			Events.on_event(se_rocket_event, this.on_se_cargo_rocket_launched)
		end
	end
end

function this.register_se_events_load()
	if storage.se_cargo_rocket_event_id then
		Events.on_event(storage.se_cargo_rocket_event_id, this.on_se_cargo_rocket_launched)
	end
end

function this.initialize()
	fLog("initialize")
	Interface.generateEvents()
	IonCannonStorage.initialize()

	storage.goToFull = storage.goToFull or {}
	storage.markers = storage.markers or {}
	storage.klaxonTick = storage.klaxonTick or 0
	storage.auto_tick = storage.auto_tick or 0
	storage.readyTick = {}
	if not storage.permissions then Permissions.initialize() end
	for _, player in pairs(game.players) do
		storage.readyTick[player.index] = 0
		if storage.goToFull[player.index] == nil then
			storage.goToFull[player.index] = true
		end
		if player.gui.top["ion-cannon-button"] then player.gui.top["ion-cannon-button"].destroy() end
		if player.gui.top["ion-cannon-stats"] then player.gui.top["ion-cannon-stats"].destroy() end
	end
	for i, force in pairs(game.forces) do
		force.reset_recipes()
	end
	if IonCannonStorage.countAll() > 0 then
		storage.IonCannonLaunched = true
		this.enableNthTick60()
	end
	this.migrate_cannon_surface_names()
	this.register_se_events_init()
end

function this.migrate_cannon_surface_names()
	if not mods["space-exploration"] then return end
	if not remote.interfaces["space-exploration"] then return end
	for _, cannons in pairs(storage.forces_ion_cannon_table) do
		if type(cannons) == "table" then
			for _, cannon in ipairs(cannons) do
				if cannon[3] then
					local resolved = IonCannon.resolvePlanetName(cannon[3])
					if resolved ~= cannon[3] then
						cannon[3] = resolved
					end
				end
			end
		end
	end
end

function this.onLoad()
	fLog("onLoad")
	Interface.generateEvents()
	if storage.IonCannonLaunched then
		this.enableNthTick60()
	end
	this.register_se_events_load()
end

function this.on_force_created(e)
	if not storage.forces_ion_cannon_table then this.initialize() end
	IonCannonStorage.newForce(e.force)
end

---@param e EventData.on_forces_merging
function this.on_forces_merging(e)
	local dest = IonCannonStorage.fromForce(e.destination)
	for _, connon in ipairs(IonCannonStorage.fromForceOrEmpty(e.source)) do
		table.insert(dest, connon)
	end
	storage.forces_ion_cannon_table[e.source.name]=nil
end


--why we should open the GUI always? KUX MODIFICATION
--[[Events.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	if event.player_index then
		local player = game.players[event.player_index]
		if global.IonCannonLaunched or player.cheat_mode or player.admin then
			open_GUI(player)
		end
	end
end)]]

function this.on_player_created(e)
	fLog("on_player_created")
	init_GUI(game.players[e.player_index])
	storage.readyTick[e.player_index] = 0
end

---@param e NthTickEventData
function this.process_60_ticks(e)
	local current_tick = e.tick
	for i = #storage.markers, 1, -1 do -- Loop over table backwards because some entries get removed within the loop
		local marker = storage.markers[i]
		if marker[2] <= current_tick then
			if marker[1] and marker[1].valid then
				marker[1].destroy()
			end
			table.remove(storage.markers, i)
		end
	end
	IonCannon.ReduceIonCannonCooldowns()
	for i, force in pairs(game.forces) do
		if IonCannon.isIonCannonReady(force) then
			for i, player in pairs(force.connected_players) do
				if storage.readyTick[player.index] < current_tick then
					storage.readyTick[player.index] = current_tick + settings.get_player_settings(player)["ion-cannon-ready-ticks"].value
					playSoundForPlayer(mod.defines.sound.ready, player)
				end
			end
		end
	end
	for i, player in pairs(game.connected_players) do
		update_GUI(player)
	end
end

--Returns true if the payer is holding the specified stack or a ghost of it
function isHolding(stack, player)
	local holding = player.cursor_stack
	if holding and holding.valid_for_read and holding.name == stack.name and holding.count >= stack.count then
		return true
	--"crafting" an item in SE remote view doesn't craft the item but instead puts a ghost of it into the cursor
	--Checking for cheat mode is a simple alternative to calling an SE remote function to check if the remote view is active
	elseif --[[player.cheat_mode and]] player.cursor_ghost and player.cursor_ghost.name == stack.name then
		return true
	end
	return false
end

---@param e EventData.on_rocket_launched
function this.on_rocket_launched(e)
	local rocket = e.rocket
	if not (rocket and rocket.valid) then return end
	local force = rocket.force

	local cargo_pod = rocket.attached_cargo_pod or rocket.cargo_pod
	if not (cargo_pod and cargo_pod.valid) then return end

	local inv = cargo_pod.get_inventory(defines.inventory.cargo_unit)
	if not inv then return end

	local ion_count = 0
	for _, item in pairs(inv.get_contents()) do
		if item.name == "orbital-ion-cannon" then
			ion_count = item.count
			break
		end
	end

	if ion_count > 0 then
		local surface = e.rocket_silo and e.rocket_silo.surface or rocket.surface
		for i = 1, ion_count do
			IonCannon.install(force, surface)
		end
		inv.remove({name = "orbital-ion-cannon", count = ion_count})
	end
end

---SE cargo rocket launched event handler
function this.on_se_cargo_rocket_launched(e)
	if not e.launched_contents then return end
	local ion_count = 0
	for _, item in pairs(e.launched_contents) do
		if item.name == "orbital-ion-cannon" then
			ion_count = (item.count or 1)
		end
	end
	if ion_count == 0 then return end

	local dest_zone_name = e.destination_zone_name
	if not dest_zone_name then return end
	local force = game.forces[e.force_name]
	if not force then return end

	local planetName = IonCannon.resolvePlanetName(dest_zone_name)
	for i = 1, ion_count do
		IonCannon.install(force, planetName)
	end
end

--- @param e EventData.on_pre_build
function this.on_pre_build(e)
	local current_tick = e.tick
	if storage.tick and storage.tick > current_tick then
		return
	end
	storage.tick = current_tick + 10
	local player = game.players[e.player_index]
	if isHolding({name = "ion-cannon-targeter", count = 1}, player) and player.force.is_chunk_charted(player.surface, Chunk.from_position(e.position)) then
		IonCannon.target(player.force, e.position, player.surface, player)
	elseif isHolding({name = "ion-cannon-targeter-mk2", count = 1}, player) and player.force.is_chunk_charted(player.surface, Chunk.from_position(e.position)) then
		IonCannon.target(player.force, e.position, player.surface, player)
	end
end

--- Called when an entity is built by a player.
--- @param e EventData.on_built_entity
function this.on_built_entity(e)
	local entity = e.entity
	if not entity.valid then return end
	local targeter_names ={"ion-cannon-targeter", "ion-cannon-targeter-mk2"}
	for _, targeter_name in ipairs(targeter_names) do
		if entity.name == targeter_name then
			local player = game.players[e.player_index]
			player.cursor_stack.set_stack({name = targeter_name, count = 1})
			entity.destroy()
			return
		end
		if entity.name == "entity-ghost" then
			if entity.ghost_name == targeter_name then
				entity.destroy()
				return
			end
		end
	end
end

---Called when an entity with a trigger prototype (such as capsules) create an entity AND that trigger prototype defined trigger_created_entity=true.
---@param e EventData.on_trigger_created_entity
function this.on_trigger_created_entity(e)
	local created_entity = e.entity
	if created_entity.name == "ion-cannon-explosion" then
		script.raise_event(when_ion_cannon_fired, {surface = created_entity.surface, position = created_entity.position, radius = IonCannon.getRadius(created_entity.force)})		-- Passes event.surface, event.position, and event.radius
		--TODO: Is this charting the chunk for every force in the game? wtf?
		for i, force in pairs(game.forces) do
			force.chart(created_entity.surface, Position.expand_to_area(created_entity.position, 1))
		end
	end
end

function Control.enableNthTick60()
	Events.on_nth_tick(60, this.process_60_ticks)
end


ModGui.initEvents()

Events.on_event(defines.events.on_force_created, this.on_force_created)
Events.on_event(defines.events.on_forces_merging,this.on_forces_merging)
Events.on_event(defines.events.on_player_created, this.on_player_created)
Events.on_event(defines.events.on_trigger_created_entity, this.on_trigger_created_entity)
Events.on_event(defines.events.on_built_entity, this.on_built_entity)
local c_on_pre_build = defines.events.on_pre_build --COMPATIBILITY 1.1 'on_put_item' renamed to 'on_pre_build'
if not c_on_pre_build then c_on_pre_build = (defines.events--[[@as any]]).on_put_item end
Events.on_event(c_on_pre_build, this.on_pre_build)
Events.on_event(defines.events.on_rocket_launched, this.on_rocket_launched)



Events.on_init(this.initialize)
Events.on_load(this.onLoad)
script.on_configuration_changed(this.initialize)

commands.add_command("ion-cannon", {"command-help.ion-cannon"}, function(event)
	local player = game.players[event.player_index] --[[@as LuaPlayer]]
	if player.admin then
		if event.parameter == "reset-gui" then
			ModGui.reset(player)
		elseif event.parameter == "research" then
			player.print("Researching Ion Cannon")
			player.force.technologies["orbital-ion-cannon"].research_recursive()
		elseif event.parameter == "research auto-targeting" then
			player.print("Researching Ion Cannon")
			player.force.technologies["auto-targeting"].research_recursive()
		else
			player.print("Unknown command "..event.parameter)
		end
	end
end)
