require('dotenv').load()
bodyParser = require('body-parser')
dateFormat = require 'dateformat'
express = require 'express'
extend = require 'extend'
morgan = require 'morgan'
_redis = require 'redis'
multer = require 'multer'
session = require 'express-session'
sassMiddleware = require 'node-sass-middleware'
connectCoffeeScript = require 'connect-coffee-script'
Path = require 'path'
Promise = require 'promise'
RedisStore = require('connect-redis') session
AWS = require 'aws-sdk'
fs = require 'fs'
http = require 'http'

if uriString = process.env.REDISTOGO_URL || process.env.BOXEN_REDIS_URL
  uri = require('url').parse uriString
  redis = _redis.createClient uri.port, uri.hostname
  redis.auth uri.auth?.split(':')?[1]
else
  redis = _redis.createClient()

app = express()
KEY_PREFIX = 'capcus:' + app.get 'env'
app.set 'view engine', 'jade'
app.set 'views', __dirname + '/views'
app.locals.moment = require 'moment'
app.locals.markdown = require("node-markdown").Markdown
app.use session {
  secret: process.env.SESSION_SECRET || '<insecure>'
  store: new RedisStore client: redis
  resave: yes
  saveUninitialized: yes
}
app.use bodyParser.json()
app.use bodyParser.urlencoded extended: yes
app.use morgan 'combined'
app.use sassMiddleware {
  src: "#{__dirname}/frontend/sass"
  dest: "#{__dirname}/public"
  debug: app.get('env') isnt 'production'
}
app.use connectCoffeeScript {
  src: "#{__dirname}/frontend/coffee"
  dest: "#{__dirname}/public"
}

uploadFile = (file) ->
  new Promise (fulfill, reject) ->
    name = file.name
    path = "uploads/#{name[0..1]}/#{name[2..]}.png"
    bucket = process.env.S3_BUCKET
    s3 = new AWS.S3()
    s3.putObject {
      Bucket: bucket
      Key: path
      ACL: 'public-read'
      ContentType: 'image/png'
      Body: file.buffer
    }, (err) ->
      if err?
        reject err
      else
        fulfill "https://#{bucket}.s3.amazonaws.com/#{path}"

app.use multer inMemory: yes
app.use express.static Path.join __dirname, 'public'

redisGet = (key) ->
  new Promise (fulfill, reject) ->
    redis.get key, (e, r) ->
      if e?
        reject e
      else
        try
          fulfill JSON.parse r
        catch
          reject e

redisSet = (key, value) ->
  new Promise (fulfill, reject) ->
    redis.set key, JSON.stringify(value), (e, r) ->
      if e?
        reject e
      else
        fulfill r

app.getCaptures = ->
  new Promise (fulfill, reject) ->
    caps = []
    redis.keys KEY_PREFIX + ':*', (e, res) ->
      if e?
        reject e
        return
      Promise.all(res.map(app.getCapture)).done (caps) ->
        fulfill caps.sort (x, y) -> x.createdAt < y.createdAt
      , reject

app.getCapture = (id) ->
  new Promise (fulfill, reject) ->
    cap = null
    redisGet(id).then (_cap) ->
      unless cap = _cap
        fulfill null
        return
      getUser cap.userId
    .then (user) ->
      cap.user = user
      cap.comments ||= []
      Promise.all cap.comments.map (comment) ->
        getUser comment.userId
    .done (commentUsers) ->
      for user, i in commentUsers
        cap.comments[i]?.user = user
      fulfill cap
    , reject

http.ServerResponse.prototype.renderError = (message, status = 403) ->
  @status(status).render 'error', message: message

getUser = (userId) ->
  new Promise (fulfill, reject) ->
    redisGet("user:#{KEY_PREFIX}:#{userId}").done (user) ->
      user ||= {}
      user.id = userId
      fulfill user

app.use (req, res, next) ->
  unless userId = req.session.userId
    return next()
  getUser(userId).done (user) ->
    req.user = user
    do next

app.get '/', (req, res) ->
  app.getCaptures()
    .done (capcuses) ->
      capcuses ||= []
      res.render 'index', {capcuses}

app.route('/me')
  .post (req, res) ->
    unless userId = req.session.userId
      res.renderError 'No userId', 400
      return
    key = "user:#{KEY_PREFIX}:#{userId}"
    {name} = req.body
    redisSet(key, {name}).done ->
      res.redirect '/me'
  .all (req, res) ->
    res.render 'me', {user: req.user}

app.param 'capcus', (req, res, next, id) ->
  app.getCapture(KEY_PREFIX + ':' + id)
    .done (cap) ->
      req.capcus = cap
      do next
    , (err) ->
      next err

app.get '/:capcus', (req, res) ->
  {capcus} = req
  if capcus?
    redisGet("items:#{KEY_PREFIX}:#{capcus.pageUrl}")
      .then (names) ->
        names ||= []
        Promise.all names.map (name) ->
          app.getCapture KEY_PREFIX + ':' + name
      .done (capcuses) ->
        capcuses ||= []
        capcuses = capcuses.filter (a) ->
          a? && a.name isnt capcus.name
        res.render 'show', {capcus, capcuses}
  else
    res.renderError 'Capcus not found', 404

app.post '/:capcus/comments', (req, res) ->
  {capcus} = req
  {comment} = req.body
  {userId} = req.session
  if capcus?
    capcus.comments ||= []
    createdAt = new Date().getTime()
    capcus.comments.push {comment,userId,createdAt}
    key = KEY_PREFIX + ':' + capcus.name
    redisSet(key, capcus).done ->
      res.redirect '/' + capcus.name + '#comments'
  else
    res.renderError 'Capcus not found', 404

app.post '/capcus', (req, res) ->
  {image} = req.files
  {pageUrl, userId} = req.body
  req.session.userId = userId
  name = image.name
  data = { name, pageUrl, userId }
  itemskey = "items:#{KEY_PREFIX}:#{pageUrl}"
  uploadFile(image).then (s3url) ->
    data.createdAt = new Date().getTime()
    data.imageUrl = s3url
    redisSet "#{KEY_PREFIX}:#{name}", data
  .then ->
    redisGet itemskey
  .then (items) ->
    items ||= []
    items.push name
    redisSet itemskey, items
  , ->
    redisSet itemskey, [name]
  .done ->
    data.url = req.protocol + '://' + req.get('host') + "/#{data.name}"
    res.json data

app.listen process.env.PORT || 3000

