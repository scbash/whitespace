{CompositeDisposable} = require 'atom'

module.exports =
class Whitespace
  constructor: ->
    @subscriptions = new CompositeDisposable
    @subscriptions.add atom.workspace.observeTextEditors (editor) =>
      @handleEvents(editor)

    @subscriptions.add atom.commands.add 'atom-workspace',
      'whitespace:remove-trailing-whitespace': =>
        if editor = atom.workspace.getActiveTextEditor()
          @removeTrailingWhitespace(editor, editor.getGrammar().scopeName)
      'whitespace:convert-tabs-to-spaces': =>
        if editor = atom.workspace.getActiveTextEditor()
          @convertTabsToSpaces(editor)
      'whitespace:convert-spaces-to-tabs': =>
        if editor = atom.workspace.getActiveTextEditor()
          @convertSpacesToTabs(editor)

    @rawRanges = []
    @modifiedRanges = []
    @ignoreDidChanged = false

  destroy: ->
    @subscriptions.dispose()

  handleEvents: (editor) ->
    buffer = editor.getBuffer()
    bufferSavedSubscription = buffer.onWillSave =>
      buffer.transact =>
        scopeDescriptor = editor.getRootScopeDescriptor()
        @ignoreDidChanged = true
        if atom.config.get('whitespace.removeTrailingWhitespace', scope: scopeDescriptor)
          @removeTrailingWhitespace(editor, editor.getGrammar().scopeName)
        if atom.config.get('whitespace.ensureSingleTrailingNewline', scope: scopeDescriptor)
          @ensureSingleTrailingNewline(editor)
        @modifiedRanges = []
        @ignoreDidChanged = false

    bufferDidChangeSubscription = buffer.onDidChange (event) =>
      # Per the Atom docs, onDidChange runs on main thread, so event handler needs to be fast.
      # Just cache the modified range, and do the real processing in onDidStopChanging.
      scopeDescriptor = editor.getRootScopeDescriptor()
      if atom.config.get('whitespace.onlyFixEditedLines', scope: scopeDescriptor) and not @ignoreDidChanged
        #console.log('new range = ' + event.newRange)
        @rawRanges.push(event.newRange)

    bufferDidStopChangingSubscription = buffer.onDidStopChanging =>
      # Collapse modified ranges into a minimal set
      # TODO is this guaranteed to be called before onWillSave?
      scopeDescriptor = editor.getRootScopeDescriptor()
      return unless atom.config.get('whitespace.onlyFixEditedLines', scope: scopeDescriptor)

      # First sort the ranges (do this in a temporary array for now...)
      all_ranges = @modifiedRanges.concat(@rawRanges)
      all_ranges.sort((a,b) -> return if a.start.row >= b.start.row then 1 else -1)
      console.log('all_ranges = ' + all_ranges)

      # Now combine overlapping ranges
      # See http://www.geeksforgeeks.org/merging-intervals/
      non_intersecting_ranges = []
      non_intersecting_ranges.unshift(all_ranges[0])
      for range in all_ranges[1..all_ranges.length]
        # TODO investigate occasional range being undef here...
        if range.start.row <= non_intersecting_ranges[0].end.row
          non_intersecting_ranges[0] = non_intersecting_ranges[0].union(range)
        else
          non_intersecting_ranges.unshift(range)
      @modifiedRanges = non_intersecting_ranges # note that this goes from end of file to beginning...
      console.log('modifiedRanges = ' + @modifiedRanges)
      @rawRanges = []

    editorTextInsertedSubscription = editor.onDidInsertText (event) ->
      return unless event.text is '\n'
      return unless buffer.isRowBlank(event.range.start.row)

      scopeDescriptor = editor.getRootScopeDescriptor()
      if atom.config.get('whitespace.removeTrailingWhitespace', scope: scopeDescriptor)
        unless atom.config.get('whitespace.ignoreWhitespaceOnlyLines', scope: scopeDescriptor)
          editor.setIndentationForBufferRow(event.range.start.row, 0)

    editorDestroyedSubscription = editor.onDidDestroy =>
      bufferSavedSubscription.dispose()
      editorTextInsertedSubscription.dispose()
      editorDestroyedSubscription.dispose()
      bufferDidChangeSubscription.dispose()
      bufferDidStopChangingSubscription.dispose()

      @subscriptions.remove(bufferSavedSubscription)
      @subscriptions.remove(editorTextInsertedSubscription)
      @subscriptions.remove(editorDestroyedSubscription)
      @subscriptions.remove(bufferDidChangeSubscription)
      @subscriptions.remove(bufferDidStopChangingSubscription)

    @subscriptions.add(bufferSavedSubscription)
    @subscriptions.add(editorTextInsertedSubscription)
    @subscriptions.add(editorDestroyedSubscription)
    @subscriptions.add(bufferDidChangeSubscription)
    @subscriptions.add(bufferDidStopChangingSubscription)

  removeTrailingWhitespace: (editor, grammarScopeName) ->
    buffer = editor.getBuffer()
    scopeDescriptor = editor.getRootScopeDescriptor()
    ignoreCurrentLine = atom.config.get('whitespace.ignoreWhitespaceOnCurrentLine', scope: scopeDescriptor)
    ignoreWhitespaceOnlyLines = atom.config.get('whitespace.ignoreWhitespaceOnlyLines', scope: scopeDescriptor)
    onlyModifiedLines = atom.config.get('whitespace.onlyFixEditedLines', scope: scopeDescriptor)

    stripWhiteSpace = ({lineText, match, replace}) ->
      whitespaceRow = buffer.positionForCharacterIndex(match.index).row
      cursorRows = (cursor.getBufferRow() for cursor in editor.getCursors())

      return if ignoreCurrentLine and whitespaceRow in cursorRows

      [whitespace] = match
      return if ignoreWhitespaceOnlyLines and whitespace is lineText

      if grammarScopeName is 'source.gfm' and atom.config.get('whitespace.keepMarkdownLineBreakWhitespace')
        # GitHub Flavored Markdown permits two or more spaces at the end of a line
        replace('') unless whitespace.length >= 2 and whitespace isnt lineText
      else
        replace('')

    if onlyModifiedLines
      for range in @modifiedRanges
        # TODO passing true for includeNewLine implies ranges are exclusive
        # (e.g. modifing row 2 produces the range [[2,0] - [3,0]], so it may be faster to just
        # create the range directly)
        firstRow = buffer.rangeForRow(range.start.row, true)
        lastRow = buffer.rangeForRow(range.end.row, true)
        console.log('starting with range ' + range + ', scanning range ' + firstRow.union(lastRow))
        buffer.backwardsScanInRange /[ \t]+$/g, firstRow.union(lastRow), stripWhiteSpace
    else
      buffer.backwardsScan /[ \t]+$/g, stripWhiteSpace

  ensureSingleTrailingNewline: (editor) ->
    buffer = editor.getBuffer()
    lastRow = buffer.getLastRow()

    if buffer.lineForRow(lastRow) is ''
      row = lastRow - 1
      buffer.deleteRow(row--) while row and buffer.lineForRow(row) is ''
    else
      selectedBufferRanges = editor.getSelectedBufferRanges()
      buffer.append('\n')
      editor.setSelectedBufferRanges(selectedBufferRanges)

  convertTabsToSpaces: (editor) ->
    buffer = editor.getBuffer()
    spacesText = new Array(editor.getTabLength() + 1).join(' ')

    buffer.transact ->
      buffer.scan /\t/g, ({replace}) -> replace(spacesText)

  convertSpacesToTabs: (editor) ->
    buffer = editor.getBuffer()
    spacesText = new Array(editor.getTabLength() + 1).join(' ')

    buffer.transact ->
      buffer.scan new RegExp(spacesText, 'g'), ({replace}) -> replace('\t')
