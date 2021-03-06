sys = require 'sys'
connect = require 'connect'
express = require 'express'

models = require './models/models'
[Team, Person] = [models.Team, models.Person]

pub = __dirname + '/public';
app = express.createServer(
  connect.compiler({ src: pub, enable: ['sass'] }),
  connect.staticProvider(pub)
)

app.use connect.logger()
app.use connect.bodyDecoder()
app.use connect.methodOverride()
app.use connect.cookieDecoder()

app.enable 'show exceptions'

request = (type) ->
  (path, fn) ->
    app[type] path, (req, res, next) =>
      Person.firstByAuthKey req.cookies.authkey, (error, person) =>
        ctx = {
          sys: sys
          req: req
          res: res
          next: next
          redirect: __bind(res.redirect, res),
          cookie: (key, value, options) ->
            value ||= ''
            options ||= {}
            cookie = "#{key}=#{value}"
            for k, v of options
              cookie += "; #{k}=#{v}"
            res.header('Set-Cookie', cookie)
          render: (file, opts) ->
            opts ||= {}
            opts.locals ||= {}
            opts.locals.view = file.replace(/\..*$/,'').replace(/\//,'-')
            opts.locals.ctx = ctx
            res.render file, opts
          currentPerson: person
          setCurrentPerson: (person, options) ->
            @cookie 'authKey', person?.authKey(), options
          redirectToTeam: (person, alternatePath) ->
            Team.first { 'members._id': person._id }, (error, team) =>
              if team?
                @redirect '/teams/' + team.id()
              else
                @redirect (alternatePath or '/')
          redirectToLogin: ->
            @redirect "/login?return_to=#{@req.url}"
          logout: (fn) ->
            @currentPerson.logout (error, resp) =>
              @setCurrentPerson null
              fn()
          canEditTeam: (team) ->
            req.cookies.teamauthkey is team.authKey() or
              team.hasMember(@currentPerson)
          ensurePermitted: (other, fn) ->
            permitted = if other.hasMember?
              @canEditTeam other
            else
              @currentPerson? and (other.id() is @currentPerson.id())
            if permitted then fn()
            else
              unless @currentPerson?
                @redirectToLogin()
              else
                # TODO flash "Oops! You don't have permissions to see that. Try logging in as somebody else."
                @logout =>
                  @redirectToLogin()}
        __bind(fn, ctx)()
get = request 'get'
post = request 'post'
put = request 'put'
del = request 'del'

get /.*/, ->
  [host, path] = [@req.header('host'), @req.url]
  if host == 'www.nodeknockout.com' or host == 'nodeknockout.heroku.com'
    @redirect "http://nodeknockout.com#{path}", 301
  else
    @next()

get '/', ->
  Team.all (error, teams) =>
    @spotsLeft = 222 - teams.length
    @render 'index.html.haml'

get '/*.js', ->
  try
    @render "#{@req.params[0]}.js.coffee", { layout: false }
  catch e
    @next()

get '/register', ->
  Team.all (error, teams) =>
    altPath = if teams.length >= 222
      "/login?return_to=#{@req.url}"
    else
      'teams/new'
    if @currentPerson?
      @redirectToTeam @currentPerson, '/teams/new'
    else
      @redirect altPath

# list teams
get '/teams', ->
  Team.all (error, teams) =>
    @teams = teams
    @yourTeams = if @currentPerson?
      _.select teams, (team) =>
        # TODO this is gross
        _ids = _.pluck(team.members, '_id')
        _.include _.pluck(_ids, 'id'), @currentPerson._id.id
    else []
    @render 'teams/index.html.haml'

get '/teams/attending', ->
  Team.all (error, teams) =>
    @joyentTotal = Team.joyentTotal teams
    @teams = _.select teams, (team) ->
      parseInt(team.joyent_count) > 0
    @render 'teams/index.html.haml'

# new team
get '/teams/new', ->
  Team.all (error, teams) =>
    if teams.length >= 222
      @redirect '/'
    else
      @joyentTotal = Team.joyentTotal teams
      @team = new Team {}, =>
        @render 'teams/new.html.haml'

# create team
post '/teams', ->
  @req.body.joyent_count = parseInt(@req.body.joyent_count) || 0
  @team = new Team @req.body, =>
    @team.save (errors, res) =>
      if errors?
        @errors = errors
        @render 'teams/new.html.haml'
      else
        @cookie 'teamAuthKey', @team.authKey()
        @redirect '/teams/' + @team.id()

# show team
get '/teams/:id', ->
  Team.all (error, teams) =>
    Team.first @req.param('id'), (error, team) =>
      if team?
        @joyentTotal = Team.joyentTotal teams
        @team = team
        people = team.members or []
        @members = _.select people, (person) -> person.name
        @invites = _.without people, @members...
        @editAllowed = @canEditTeam team
        @render 'teams/show.html.haml'
      else
        # TODO make this a 404
        @redirect '/'

# edit team
get '/teams/:id/edit', ->
  Team.all (error, teams) =>
    Team.first @req.param('id'), (error, team) =>
      @ensurePermitted team, =>
        @joyentTotal = Team.joyentTotal teams
        @team = team
        @render 'teams/edit.html.haml'

# update team
put '/teams/:id', ->
  Team.first @req.param('id'), (error, team) =>
    @ensurePermitted team, =>
      team.joyent_count ||= 0
      @req.body.joyent_count = parseInt(@req.body.joyent_count) || 0
      team.update @req.body
      save = =>
        team.save (errors, result) =>
          if errors?
            @errors = errors
            @team = team
            if @req.xhr
              @res.send 'ERROR', 500
            else
              @render 'teams/edit.html.haml'
          else
            if @req.xhr
              @res.send 'OK', 200
            else
              @redirect '/teams/' + team.id()
      # TODO shouldn't need this
      if @req.body.emails
        team.setMembers @req.body.emails, save
      else save()

# delete team
del '/teams/:id', ->
  Team.first @req.param('id'), (error, team) =>
    @ensurePermitted team, =>
      team.remove (error, result) =>
        @redirect '/'

# resend invitation
get '/teams/:teamId/invite/:personId', ->
  Team.first @req.param('teamId'), (error, team) =>
    @ensurePermitted team, =>
      Person.first @req.param('personId'), (error, person) =>
        person.inviteTo team, =>
          if @req.xhr
            @res.send 'OK', 200
          else
            # TODO flash "Sent a new invitation to $@person.email"
            @redirect '/teams/' + team.id()

# sign in
get '/login', ->
  @person = new Person()
  @render 'login.html.haml'

post '/login', ->
  Person.login @req.body, (error, person) =>
    if person?
      if @req.param 'remember'
        d = new Date()
        d.setTime(d.getTime() + 1000 * 60 * 60 * 24 * 180)
        options = { expires: d }
      @setCurrentPerson person, options
      if person.name
        if returnTo = @req.param('return_to')
          @redirect returnTo
        else @redirectToTeam person
      else
        @redirect '/people/' + person.id() + '/edit'
    else
      @errors = error
      @person = new Person(@req.body)
      @render 'login.html.haml'

get '/logout', ->
  @redirect '/' unless @currentPerson?
  @logout =>
    @redirect '/'

# reset password
post '/reset_password', ->
  Person.first { email: @req.param('email') }, (error, person) =>
    # TODO assumes xhr
    unless person?
      @res.send 'Email not found', 404
    else
      person.resetPassword =>
        @res.send 'OK', 200

# edit person
get '/people/:id/edit', ->
  Person.first @req.param('id'), (error, person) =>
    @ensurePermitted person, =>
      @person = person
      @render 'people/edit.html.haml'

# update person
put '/people/:id', ->
  Person.first @req.param('id'), (error, person) =>
    @ensurePermitted person, =>
      attributes = @req.body

      # TODO this shouldn't be necessary
      person.setPassword attributes.password if attributes.password
      delete attributes.password

      attributes.link = '' unless /^https?:\/\/.+\./.test attributes.link
      person.update attributes
      person.save (error, resp) =>
        @redirectToTeam person

get '/*', ->
  try
    @render "#{@req.params[0]}.html.haml"
  catch e
    throw e if e.errno != 2
    @next()

server = app.listen parseInt(process.env.PORT || 8000), null
