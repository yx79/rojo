local StudioService = game:GetService("StudioService")

local Log = require(script.Parent.Parent.Log)
local Fmt = require(script.Parent.Parent.Fmt)
local t = require(script.Parent.Parent.t)

local InstanceMap = require(script.Parent.InstanceMap)
local Reconciler = require(script.Parent.Reconciler)
local strict = require(script.Parent.strict)

local Status = strict("Session.Status", {
	NotStarted = "NotStarted",
	Connecting = "Connecting",
	Connected = "Connected",
	Disconnected = "Disconnected",
})

local function debugPatch(patch)
	return Fmt.debugify(patch, function(patch, output)
		output:writeLine("Patch {{")
		output:indent()

		for removed in ipairs(patch.removed) do
			output:writeLine("Remove ID {}", removed)
		end

		for id, added in pairs(patch.added) do
			output:writeLine("Add ID {} {:#?}", id, added)
		end

		for _, updated in ipairs(patch.updated) do
			output:writeLine("Update ID {} {:#?}", updated.id, updated)
		end

		output:unindent()
		output:write("}")
	end)
end

local ServeSession = {}
ServeSession.__index = ServeSession

ServeSession.Status = Status

local validateServeOptions = t.strictInterface({
	apiContext = t.table,
	openScriptsExternally = t.boolean,
	twoWaySync = t.boolean,
})

function ServeSession.new(options)
	assert(validateServeOptions(options))

	-- Declare self ahead of time to capture it in a closure
	local self
	local function onInstanceChanged(instance, propertyName)
		self:__onInstanceChanged(instance, propertyName)
	end

	local instanceMap = InstanceMap.new(onInstanceChanged)
	local reconciler = Reconciler.new(instanceMap)

	local connections = {}

	local connection = StudioService
		:GetPropertyChangedSignal("ActiveScript")
		:Connect(function()
			local activeScript = StudioService.ActiveScript

			if activeScript ~= nil then
				self:__onActiveScriptChanged(activeScript)
			end
		end)
	table.insert(connections, connection)

	self = {
		__status = Status.NotStarted,
		__apiContext = options.apiContext,
		__openScriptsExternally = options.openScriptsExternally,
		__twoWaySync = options.twoWaySync,
		__reconciler = reconciler,
		__instanceMap = instanceMap,
		__statusChangedCallback = nil,
		__connections = connections,
	}

	setmetatable(self, ServeSession)

	return self
end

function ServeSession:__fmtDebug(output)
	output:writeLine("ServeSession {{")
	output:indent()

	output:writeLine("API Context: {:#?}", self.__apiContext)
	output:writeLine("Instances: {:#?}", self.__instanceMap)

	output:unindent()
	output:write("}")
end

function ServeSession:onStatusChanged(callback)
	self.__statusChangedCallback = callback
end

function ServeSession:start()
	self:__setStatus(Status.Connecting)

	self.__apiContext:connect()
		:andThen(function(serverInfo)
			self:__setStatus(Status.Connected)

			local rootInstanceId = serverInfo.rootInstanceId

			return self:__initialSync(rootInstanceId)
				:andThen(function()
					return self:__mainSyncLoop()
				end)
		end)
		:catch(function(err)
			self:__stopInternal(err)
		end)
end

function ServeSession:stop()
	self:__stopInternal()
end

function ServeSession:__onActiveScriptChanged(activeScript)
	if not self.__openScriptsExternally then
		Log.trace("Not opening script {} because feature not enabled.", activeScript)

		return
	end

	if self.__status ~= Status.Connected then
		Log.trace("Not opening script {} because session is not connected.", activeScript)

		return
	end

	local scriptId = self.__instanceMap.fromInstances[activeScript]
	if scriptId == nil then
		Log.trace("Not opening script {} because it is not known by Rojo.", activeScript)

		return
	end

	Log.debug("Trying to open script {} externally...", activeScript)

	-- Force-close the script inside Studio
	local existingParent = activeScript.Parent
	activeScript.Parent = nil
	activeScript.Parent = existingParent

	-- Notify the Rojo server to open this script
	self.__apiContext:open(scriptId)
end

function ServeSession:__onInstanceChanged(instance, propertyName)
	if not self.__twoWaySync then
		return
	end

	local instanceId = self.__instanceMap.fromInstances[instance]

	if instanceId == nil then
		Log.warn("Ignoring change for instance {:?} as it is unknown to Rojo", instance)
		return
	end

	local remove = nil

	local update = {
		id = instanceId,
		changedProperties = {},
	}

	if propertyName == "Name" then
		update.changedName = instance.Name
	elseif propertyName == "Parent" then
		if instance.Parent == nil then
			update = nil
			remove = instanceId
		else
			Log.warn("Cannot sync non-nil Parent property changes yet")
			return
		end
	else
		local success, encoded = self.__reconciler:encodeApiValue(instance[propertyName])

		if not success then
			Log.warn("Could not sync back property {:?}.{}", instance, propertyName)
			return
		end

		update.changedProperties[propertyName] = encoded
	end

	local patch = {
		removed = {remove},
		added = {},
		updated = {update},
	}

	self.__apiContext:write(patch)
end

function ServeSession:__initialSync(rootInstanceId)
	return self.__apiContext:read({ rootInstanceId })
		:andThen(function(readResponseBody)
			-- Tell the API Context that we're up-to-date with the version of
			-- the tree defined in this response.
			self.__apiContext:setMessageCursor(readResponseBody.messageCursor)

			Log.trace("Computing changes that plugin needs to make to catch up to server...")

			-- Calculate the initial patch to apply to the DataModel to catch us
			-- up to what Rojo thinks the place should look like.
			local hydratePatch = self.__reconciler:hydrate(
				readResponseBody.instances,
				rootInstanceId,
				game
			)

			Log.trace("Computed hydration patch: {:#?}", debugPatch(hydratePatch))

			-- TODO: Prompt user to notify them of this patch, since it's
			-- effectively a conflict between the Rojo server and the client.

			self.__reconciler:applyPatch(hydratePatch)
		end)
end

function ServeSession:__mainSyncLoop()
	return self.__apiContext:retrieveMessages()
		:andThen(function(messages)
			for _, message in ipairs(messages) do
				self.__reconciler:applyPatch(message)
			end

			if self.__status ~= Status.Disconnected then
				return self:__mainSyncLoop()
			end
		end)
end

function ServeSession:__stopInternal(err)
	self:__setStatus(Status.Disconnected, err)
	self.__apiContext:disconnect()
	self.__instanceMap:stop()

	for _, connection in ipairs(self.__connections) do
		connection:Disconnect()
	end
	self.__connections = {}
end

function ServeSession:__setStatus(status, detail)
	self.__status = status

	if self.__statusChangedCallback ~= nil then
		self.__statusChangedCallback(status, detail)
	end
end

return ServeSession