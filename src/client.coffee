https       = require 'https'
querystring = require 'querystring'
WebSocket   = require 'ws'
{EventEmitter} = require 'events'

User = require './user'
Team = require './team'
Channel = require './channel'
Group = require './group'
DM = require './dm'
Message = require './message'
Bot = require './bot'

class Client extends EventEmitter

  host: 'api.slack.com'

  constructor: (@token) ->
    @authenticated  = false
    @connected      = false

    @self           = null
    @team           = null

    @channels       = {}
    @dms            = {}
    @groups         = {}
    @users          = {}
    @bots           = {}

    @socketUrl      = null
    @ws             = null
    @_messageID     = 0
    @_pending       = {}

  #
  # Logging in and connection management functions
  #

  login: ->
    console.log 'Connecting...'
    @_apiCall 'users.login', {agent: 'node-slack'}, @_onLogin

  _onLogin: (data) =>
    if data
      if not data.ok
        @emit 'error', data.error
        @authenticated = false
      else
        @authenticated = true

        # Important information about ourselves
        @self = new User @, data.self
        @team = new Team @, data.team.id, data.team.name, data.team.domain

        # Stash our websocket url away for later -- must be used within 30 seconds!
        @socketUrl = data.url

        # Stash our list of other users (DO THIS FIRST)
        for k of data.users
          u = data.users[k]
          @users[u.id] = new User @, u

        # Stash our list of channels
        for k of data.channels
          c = data.channels[k]
          @channels[c.id] = new Channel @, c

        # Stash our list of dms
        for k of data.ims
          i = data.ims[k]
          @dms[i.id] = new DM @, i

        # Stash our list of private groups
        for k of data.groups
          g = data.groups[k]
          @groups[g.id] = new Group @, g

        # TODO: Process bots

        @emit 'loggedIn', @self, @team
        @connect()
    else
      @emit 'error'

  connect: ->
    if not @socketUrl
      return false
    else
      @ws = new WebSocket @socketUrl
      @ws.on 'open', =>
        @emit 'open'
        @connected = true

        # start pings
        @_pongTimeout = setInterval =>
          if not @connected then return

          @_send {"type": "ping"}
          if @_lastPong? and Date.now() - @_lastPong > 10000
            console.log "Last pong is too old: %d", (Date.now() - @_lastPong) / 1000
            @disconnect()
        , 5000

      @ws.on 'message', (data, flags) =>
        # flags.binary will be set if a binary data is received
        # flags.masked will be set if the data was masked
        @onMessage JSON.parse(data)

      @ws.on 'error', =>
        @emit 'error'

      @ws.on 'close', =>
        @emit 'close'
        @connected = false
        @socketUrl = null

      @ws.on 'ping', (data, flags) =>
        @ws.pong

      return true

  disconnect: =>
    if not @connected
      return false
    else
      if @_pongTimeout
        clearInterval @_pongTimeout
        @_pongTimeout = null

      # We don't set any flags or anything here, since the event handling on the socket will do it
      @ws.close()
      return true

  joinChannel: (name) ->
    params = {
      "name": name
    }

    @_apiCall 'channels.join', params, @_onJoinChannel

  _onJoinChannel: (data) =>
    console.log data

  openDM: (user_id) ->
    params = {
      "user": user_id
    }

    @_apiCall 'im.open', params, @_onOpenDM

  _onOpenDM: (data) =>
    console.log data

  createGroup: (name) ->
    params = {
      "name": name
    }

    @_apiCall 'groups.create', params, @_onCreateGroup

  _onCreateGroup: (data) =>
    console.log data

  setPresence: (presence) ->
    if presence is not 'away' and presence is not 'active' then return null

    params = {
      "presence": presence
    }

    @_apiCall 'presence.set', params, @_onSetPresence

  _onSetPresence: (data) =>
    console.log data

  setActive: ->
    params = {}

    @_apiCall 'users.setActive', params, @_onSetActive

  _onSetActive: (data) =>
    console.log data

  setStatus: (status) ->
    params = {
      "status": status
    }

    @_apiCall 'status.set', params, @_onSetStatus

  _onSetStatus: (data) =>
    console.log data

  #
  # Utility functions
  #

  getUserByID: (id) ->
    @users[id]

  getUserByName: (name) ->
    for k of @users
      if @users[k].name == name
        return @users[k]

  getChannelByID: (id) ->
    @channels[id]

  getChannelByName: (name) ->
    for k of @channels
      if @channels[k].name == name
        return @channels[k]

  getDMByID: (id) ->
    @dms[id]

  getDMByName: (name) ->
    for k of @dms
      if @dms[k].name == name
        return @dms[k]

  getGroupByID: (id) ->
    @groups[id]

  getGroupByName: (name) ->
    for k of @groups
      if @groups[k].name == name
        return @groups[k]

  getChannelGroupOrDMByID: (id) ->
    if id[0] == 'C'
      return @getChannelByID id
    else
      if id[0] == 'G'
        return @getGroupByID id
      else
        return @getDMByID id

  getChannelGroupOrDMByName: (name) ->
    console.log name
    channel = @getChannelByName name
    if not channel
      group = @getGroupByName name
      if not group
        return @getDMByName name
      else
        return group
    else
      return channel

  getUnreadCount: ->
    count = 0
    for id, channel of @channels
      if channel.unread_count? then count += channel.unread_count

    for id, dm of @ims
      if dm.unread_count? then count += dm.unread_count

    for id, group of @groups
      if group.unread_count? then count += group.unread_count

    count

  #
  # Message handler callback and dispatch
  #

  onMessage: (message) ->
    @emit 'raw_message', message

    # Internal handling
    switch message.type
      when "hello"
        # connected really really
        @connected = true

      when "presence_change"
        # find user by id and change their presence
        u = @getUserByID(message.user)
        if u
          @emit 'presenceChange', u, message.presence
          u.presence = message.presence

      when "manual_presence_change"
        @self.presence = message.presence

      when "status_change"
        # find user by id and change their status
        u = @getUserByID(message.user)
        if u
          @emit 'statusChane', u, message.status
          u.status = message.status

      when "error"
        @emit 'error', message.error

      when "message"
        # is this the special message we get on reconnect?
        if message.reply_to
          if @_pending[message.reply_to]
            delete @_pending[message.reply_to]
          else
            return

        # find channel/group/dm and add it to history
        m = new Message @, message
        @emit 'message', m

        channel = @getChannelGroupOrDMByID message.channel
        if channel
          channel.addMessage m

      when "channel_marked", "im_marked"
        channel = @getChannelGroupOrDMByID message.channel
        if channel
          @emit 'channelMarked', channel, message.ts
          channel.last_read = message.ts

      when "user_typing"
        user = @getUserByID message.user
        channel = @getChannelGroupOrDMByID message.channel
        if user and channel
          @emit 'userTyping', user, channel
          channel.startedTyping(user.id)
        else if channel
          console.warn "Could not find user "+message.user+" for user_typing"
        else if user
          console.warn "Could not find channel "+message.channel+" for user_typing"
        else
          console.warn "Could not find channel/user "+message.channel+"/"+message.user+" for user_typing"

      when "team_join", "user_change"
        u = message.user
        @users[u.id] = new User @, u

      when "channel_joined"
        @channels[message.channel.id] = new Channel @, message.channel

      when "channel_left"
        if @channels[message.channel]
          for k of @channels[message.channel]
            if k not in ["id", "name", "created", "creator", "is_archived", "is_general"]
              delete @channels[message.channel][k]

            @channels[message.channel].is_member = false

      when "channel_created"
        @channels[message.channel.id] = new Channel @, message.channel

      when "channel_deleted"
        delete @channels[message.channel]

      when "channel_rename"
        @channels[message.channel.id] = new Channel @, message.channel

      when "channel_archive"
        if @channels[message.channel] then @channels[message.channel].is_archived = true

      when "channel_unarchive"
        if @channels[message.channel] then @channels[message.channel].is_archived = false

      when "im_created"
        @dms[message.channel.id] = new DM @, message.channel

      when "im_open"
        if @dms[message.channel] then @dms[message.channel].is_open = true

      when "im_close"
        if @dms[message.channel] then @dms[message.channel].is_open = false

      when "group_joined"
        @groups[message.channel.id] = new Group @, message.channel

      when "group_close"
        if @groups[message.channel] then @groups[message.channel].is_open = false

      when "group_open"
        if @groups[message.channel] then @groups[message.channel].is_open = true

      when "group_left", "group_deleted"
        delete @groups[message.channel]

      when "group_archive"
        if @groups[message.channel] then @groups[message.channel].is_archived = true

      when "group_unarchive"
        if @groups[message.channel] then @groups[message.channel].is_archived = false

      when "group_rename"
        @groups[message.channel.id] = new Channel @, message.channel

      when "pref_change"
        @self.prefs[message.name] = message.value

      when "team_pref_change"
        @team.prefs[message.name] = message.value

      when "team_rename"
        @team.name = message.name

      when "team_domain_change"
        @team.domain = message.domain

      when "bot_added", "bot_changed"
        @bots[message.bot.id] = new Bot @, message.bot

      when "bot_removed"
        if @bots[message.bot.id] then @emit 'botRemoved', @bots[message.bot.id]

      else
        if message.reply_to
          if message.type == 'pong'
            @_lastPong = Date.now()
            delete @_pending[message.reply_to]
          else if message.ok
            console.log "Message "+message.reply_to+" was sent"
            if @_pending[message.reply_to]
              m = @_pending[message.reply_to]
              channel = @getChannelGroupOrDMByID m
              if channel
                channel.addMessage m

              @emit 'messageSent', m
              delete @_pending[message.reply_to]
          else
            @emit 'error', if message.error? then message.error else message
            # TODO: resend?
        else
          if message.type not in ["file_created", "file_shared", "file_unshared", "file_comment", "file_public", "file_comment_edited", "file_comment_deleted", "file_change", "file_deleted", "star_added", "star_removed"]
            console.warn 'Unknown message type: '+message.type
            console.log message

  #
  # Private functions
  #

  _send: (message) ->
    if not @connected
      return false
    else
      message.id = ++@_messageID
      @_pending[message.id] = message
      @ws.send JSON.stringify(message)

  _apiCall: (method, params, callback) ->
    params['token'] = @token

    post_data = querystring.stringify(params)

    options = 
      hostname: @host,
      method: 'POST',
      path: '/api/' + method,
      headers:
        'Content-Type': 'application/x-www-form-urlencoded',
        'Content-Length': post_data.length

    req = https.request(options)

    req.on 'response', (res) =>
      buffer = ''
      res.on 'data', (chunk) ->
        buffer += chunk
      res.on 'end', =>
        if callback?
          if res.statusCode is 200
            value = JSON.parse(buffer)
            callback(value)
          else
            callback(null)

    req.on 'error', (error) =>
      if callback? then callback({'ok': false, 'data': error})

    req.write('' + post_data)
    req.end()

module.exports = Client