# This file handles all the fetching and displaying logic. It doesn't handle any of the pane magic.

path = require 'path'
fs = require 'fs-plus'
{Emitter, Disposable, CompositeDisposable, Point} = require 'atom'
{$$$, ScrollView} = require 'atom-space-pen-views'

Q = require 'q'
slash = require 'slash'
ignore = require 'ignore'

module.exports =
class ShowTodoView extends ScrollView
  maxLength: 120

  @content: ->
    @div class: 'show-todo-preview native-key-bindings', tabindex: -1

  constructor: ({@filePath}) ->
    super
    @handleEvents()
    @emitter = new Emitter
    @disposables = new CompositeDisposable

  destroy: ->
    @cancelScan()
    @detach()
    @disposables.dispose()

  getTitle: ->
    "Todo-Show Results"

  getURI: ->
    "todolist-preview://#{@getPath()}"

  getPath: ->
    "TODOs"

  getProjectPath: ->
    atom.project.getPaths()[0]

  onDidChangeTitle: -> new Disposable()
  onDidChangeModified: -> new Disposable()

  showLoading: ->
    @loading = true
    @html $$$ ->
      @div class: 'markdown-spinner'
      @h5 class: 'text-center searched-count', 'Loading Todos...'

  showTodos: (regexes) ->
    @html $$$ ->
      @div class: 'todo-action-items pull-right', =>
        @a class: 'todo-save-as', =>
          @span class: 'icon icon-cloud-download'
        @a class: 'todo-refresh', =>
          @span class: 'icon icon-sync'

      for regex in regexes
        @section =>
          @h1 =>
            @span regex.title + ' '
            @span class: 'regex', regex.regex
          @table =>
            for result in regex.results
              relativePath = atom.project.relativize(result.filePath)

              for match in result.matches
                @tr =>
                  @td match.matchText
                  @td =>
                    # Make sure range is serialized to produce correct rendered format
                    # See https://github.com/jamischarles/atom-todo-show/issues/27
                    range = match.range.toString()
                    range = match.range.serialize().toString() if match.range.serialize

                    @a class: 'todo-url', 'data-uri': result.filePath, 'data-coords': range, relativePath

    @loading = false

  # Get regexes to look for from settings
  buildRegexLookups: (settingsRegexes) ->
    for regex, i in settingsRegexes by 2
      'title': regex
      'regex': settingsRegexes[i+1]
      'results': []

  # Pass in string and returns a proper RegExp object
  makeRegexObj: (regexStr) ->
    # Extract the regex pattern (anything between the slashes)
    pattern = regexStr.match(/\/(.+)\//)?[1]
    # Extract the flags (after last slash)
    flags = regexStr.match(/\/(\w+$)/)?[1]

    return false unless pattern
    new RegExp(pattern, flags)

  # Parses and strips result from workplace scan
  handleScanResult: (result, regex) ->
    # Loop through the workspace file results
    for regExMatch in result.matches
      matchText = regExMatch.matchText

      # Strip out the regex token from the found annotation
      # not all objects will have an exec match
      while (match = regex?.exec(matchText))
        matchText = match.pop()

      # Strip common block comment endings and whitespaces
      matchText = matchText.replace(/(\*\/|-->|#>|-}|\]\])\s*$/, '').trim()

      # Truncate long match strings
      if matchText.length >= @maxLength
        matchText = matchText.substring(0, @maxLength - 3) + '...'

      regExMatch.matchText = matchText
    result

  # Scan project for the lookup that is passed
  # returns a promise that the scan generates
  fetchRegexItem: (regexLookup) ->
    regex = @makeRegexObj(regexLookup.regex)
    return false unless regex

    # Handle ignores from settings
    ignoresFromSettings = atom.config.get('todo-show.ignoreThesePaths')
    hasIgnores = ignoresFromSettings?.length > 0
    ignoreRules = ignore({ ignore:ignoresFromSettings })

    # TODO: Use paths option as ignoreRules by adding them as an array
    # of exclusions (!) after atom fix: https://github.com/atom/atom/pull/6386
    # otherwise use full pattern; e.g. `!*/node_modules/**/*.*`
    # This would hopefully also remove dependency on slash and ignore, while
    # using default node-minimatch.

    # Only track progress on first scan
    options = {}
    if !@firstRegex
      @firstRegex = true
      onPathsSearched = (nPaths) =>
        if @loading
          @find('.searched-count').text("#{nPaths} paths searched...")
      options = {paths: '*', onPathsSearched}

    atom.workspace.scan regex, options, (result, error) =>
      console.debug error.message if error

      if result
        # Check against ignored paths
        pathToTest = slash(result.filePath.substring(atom.project.getPaths()[0].length))
        return if (hasIgnores && ignoreRules.filter([pathToTest]).length == 0)

        regexLookup.results.push @handleScanResult(result, regex)

  renderTodos: ->
    @showLoading()

    # Fetch the regexes from settings
    regexes = @buildRegexLookups(atom.config.get('todo-show.findTheseRegexes'))

    # FIXME: Abstract this into a separate, testable function?
    @searchPromises = []
    for regexObj in regexes
      # Scan the project for each regex, and get correct promises
      promise = @fetchRegexItem(regexObj)
      @searchPromises.push(promise)

    # Fire callback when ALL project scans are done
    Q.all(@searchPromises).then () =>
      @showTodos(@regexes = regexes)

    return this

  cancelScan: ->
    for promise in @searchPromises
      promise.cancel() if promise

  handleEvents: ->
    atom.commands.add @element,
      'core:save-as': (event) =>
        event.stopPropagation()
        @saveAs()
      'core:refresh': (event) =>
        event.stopPropagation()
        @renderTodos()

    @on 'click', '.todo-url',  (e) =>
      link = e.target
      @openPath(link.dataset.uri, link.dataset.coords.split(','))
    @on 'click', '.todo-save-as', =>
      @saveAs()
    @on 'click', '.todo-refresh', =>
      @renderTodos()

  # Open a new window, and load the file that we need.
  # we call this from the results view. This will open the result file in the left pane.
  openPath: (filePath, cursorCoords) ->
    return unless filePath

    atom.workspace.open(filePath, split: 'left').done =>
      @moveCursorTo(cursorCoords)

  # Open document and move cursor to positon
  moveCursorTo: (cursorCoords) ->
    lineNumber = parseInt(cursorCoords[0])
    charNumber = parseInt(cursorCoords[1])

    if textEditor = atom.workspace.getActiveTextEditor()
      position = [lineNumber, charNumber]
      textEditor.setCursorBufferPosition(position, autoscroll: false)
      textEditor.scrollToCursorPosition(center: true)

  getMarkdown: ->
    @regexes.map((regex) ->
      return unless regex.results.length

      out = '\n## ' + regex.title + '\n\n'

      regex.results?.map((result) ->
        result.matches?.map((match) ->
          out += '- ' + match.matchText
          out += ' _(' + atom.project.relativize(result.filePath) + ')_\n'
        )
      )
      out
    ).join("")

  saveAs: ->
    return if @loading

    filePath = path.parse(@getPath()).name + '.txt'
    if @getProjectPath()
      filePath = path.join(@getProjectPath(), filePath)

    if outputFilePath = atom.showSaveDialogSync(filePath)
      fs.writeFileSync(outputFilePath, @getMarkdown())
      atom.workspace.open(outputFilePath)
