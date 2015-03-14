$ ->
  $('[data-toggle="tooltip"]').tooltip()
  do onResize = ->
    $('img.capture').css 'max-height', (window.innerHeight - 20) + 'px'
  $(window).on 'resize', onResize
