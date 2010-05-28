json: JSON.stringify

get '*', ->
  [host, path]: [@headers.host, @url.href]
  if host == 'nodeknockout.com' or host == 'nodeknockout.heroku.com'
    @redirect 'http://www.nodeknockout.com' + path
  else
    @pass()

get '/', ->
  @render 'index.html.haml'

get '/*.js', (file) ->
  try
    @render "${file}.js.coffee", { layout: false }
  catch e
    @pass "/${file}.js"

get '/*.css', (file) ->
  @render "${file}.css.sass", { layout: false }

get '/*', (file) ->
  @pass "/public/${file}"

server: run parseInt(process.env.PORT || 8000), null