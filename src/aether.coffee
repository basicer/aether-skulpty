self = window if window? and not self?
self = global if global? and not self?
self.self ?= self

_ = window?._ ? self?._ ? global?._ ? require 'lodash'  # rely on lodash existing, since it busts CodeCombat to browserify it--TODO

esprima = require 'esprima'  # getting our Esprima Harmony

defaults = require './defaults'
problems = require './problems'
execution = require './execution'
traversal = require './traversal'
transforms = require './transforms'
protectBuiltins = require './protectBuiltins'
optionsValidator = require './validators/options'
languages = require './languages/languages'
interpreter = require './interpreter'

module.exports = class Aether
  @execution: execution
  @addGlobal: protectBuiltins.addGlobal  # Call instance method version after instance creation to update existing global list
  @replaceBuiltin: protectBuiltins.replaceBuiltin
  @globals: protectBuiltins.addedGlobals

  # Current call depth
  depth: 0

  getAddedGlobals: () ->
    protectBuiltins.addedGlobals

  addGlobal: (name, value) ->
    # Call class method version before instance creation to instantiate global list
    if @esperEngine?
      @esperEngine.addGlobal name, value

  constructor: (options) ->
    options ?= {}
    validationResults = optionsValidator options
    unless validationResults.valid
      throw new Error "Aether options are invalid: " + JSON.stringify(validationResults.errors, null, 4)

    # Save our original options for recreating this Aether later.
    @originalOptions = _.cloneDeep options  # TODO: slow

    # Merge the given options with the defaults.
    defaultsCopy = _.cloneDeep defaults
    @options = _.merge defaultsCopy, options

    @setLanguage @options.language
    @allGlobals = @options.globals.concat protectBuiltins.builtinNames, Object.keys(@language.runtimeGlobals)  # After setLanguage, which can add globals.
    #if statementStack[0]?
    #  rng = statementStack[0].originalRange
    #  aether.lastStatementRange = [rng.start, rng.end] if rng

    Object.defineProperty @, 'lastStatementRange',
      get: () -> 
        rng = @esperEngine?.evaluator?.lastASTNodeProcessed?.originalRange
        return [rng.start, rng.end] if rng

  # Language can be changed after construction. (It will reset Aether's state.)
  setLanguage: (language) ->
    return if @language and @language.id is language
    validationResults = optionsValidator language: language
    unless validationResults.valid
      throw new Error "New language is invalid: " + JSON.stringify(validationResults.errors, null, 4)
    @originalOptions.language = @options.language = language
    @language = new languages[language]()
    @languageJS ?= if language is 'javascript' then @language else new languages.javascript 'ES5'
    @reset()
    return language

  # Resets the state of Aether, readying it for a fresh transpile.
  reset: ->
    @problems = errors: [], warnings: [], infos: []
    @style = {}
    @flow = {}
    @metrics = {}
    @pure = null

  # Convert to JSON so we can pass it across web workers and HTTP requests and store it in databases and such.
  serialize: ->
    _.pick @, ['originalOptions', 'raw', 'pure', 'problems', 'flow', 'metrics', 'style', 'ast']

  # Convert a serialized Aether instance back from JSON.
  @deserialize: (serialized) ->
    aether = new Aether serialized.originalOptions
    aether[prop] = val for prop, val of serialized when prop isnt "originalOptions"
    aether

  # Performs quick heuristics to determine whether the code will run or produce compilation errors.
  # If thorough, it will perform detailed linting and return false if there are any lint errors.
  canTranspile: (rawCode, thorough=false) ->
    return true if not rawCode # blank code should compile, but bypass the other steps
    return false if @language.obviouslyCannotTranspile rawCode
    return true unless thorough
    @lint(rawCode, @).errors.length is 0

  # Determine whether two strings of code are significantly different.
  # If careAboutLineNumbers, we strip trailing comments and whitespace and compare line count.
  # If careAboutLint, we also lint and make sure lint problems are the same.
  hasChangedSignificantly: (a, b, careAboutLineNumbers=false, careAboutLint=false) ->
    return true unless a? and b?
    return false if a is b
    return true if careAboutLineNumbers and @language.hasChangedLineNumbers a, b
    return true if careAboutLint and @hasChangedLintProblems a, b
    # If the simple tests fail, we compare abstract syntax trees for equality.
    @language.hasChangedASTs a, b

  # Determine whether two strings of code produce different lint problems.
  hasChangedLintProblems: (a, b) ->
    aLintProblems = ([p.id, p.message, p.hint] for p in @getAllProblems @lint a)
    bLintProblems = ([p.id, p.message, p.hint] for p in @getAllProblems @lint b)
    return not _.isEqual aLintProblems, bLintProblems

  # Return a beautified representation of the code (cleaning up indentation, etc.)
  beautify: (rawCode) ->
    @language.beautify rawCode, @

  # Transpile it. Even if it can't transpile, it will give syntax errors and warnings and such. Clears any old state.
  transpile: (@raw) ->
    @reset()
    rawCode = @raw
    if @options.simpleLoops
      rawCode = _.cloneDeep @raw
      [rawCode, @replacedLoops, loopProblems] = @language.replaceLoops rawCode
    @problems = @lint rawCode
    loopProblems ?= []
    if loopProblems.length > 0
      @problems.warnings.push loopProblems...
    @pure = @purifyCode rawCode
    @pure

  # Perform some fast static analysis (without transpiling) and find any lint problems.
  lint: (rawCode) ->
    lintProblems = errors: [], warnings: [], infos: []
    @addProblem problem, lintProblems for problem in @language.lint rawCode, @
    lintProblems

  # Return a ready-to-interpret function from the parsed code.
  createFunction: ->
    return interpreter.createFunction @

  # Like createFunction, but binds method to thisValue.
  createMethod: (thisValue) ->
    _.bind @createFunction(), thisValue

  # Convenience wrapper for running the compiled function with default error handling
  run: (fn, args...) ->
    try
      fn ?= @createFunction()
    catch error
      problem = @createUserCodeProblem error: error, code: @raw, type: 'transpile', reporter: 'aether'
      @addProblem problem
      return
    try
      fn args...
    catch error
      problem = @createUserCodeProblem error: error, code: @raw, type: 'runtime', reporter: 'aether'
      @addProblem problem
      return

  # Create a standard Aether problem object out of some sort of transpile or runtime problem.
  createUserCodeProblem: problems.createUserCodeProblem

  createThread: (fx) ->
    interpreter.createThread @, fx

  updateProblemContext: (problemContext) ->
    @options.problemContext = problemContext

  # Add problem to the proper level's array within the given problems object (or @problems).
  addProblem: (problem, problems=null) ->
    return if problem.level is "ignore"
    (problems ? @problems)[problem.level + "s"].push problem
    problem

  # Return all the problems as a flat array.
  getAllProblems: (problems) ->
    _.flatten _.values (problems ? @problems)

  # The meat of the transpilation.
  purifyCode: (rawCode) ->
    preprocessedCode = @language.hackCommonMistakes rawCode, @  # TODO: if we could somehow not change the source ranges here, that would be awesome.... but we'll probably just need to get rid of this step.
    wrappedCode = @language.wrap preprocessedCode, @

    originalNodeRanges = []
    varNames = {}
    varNames[parameter] = true for parameter in @options.functionParameters
    preNormalizationTransforms = [
      transforms.makeGatherNodeRanges originalNodeRanges, wrappedCode, @language.wrappedCodePrefix
      transforms.makeCheckThisKeywords @allGlobals, varNames, @language, @options.problemContext
      transforms.makeCheckIncompleteMembers @language, @options.problemContext
    ]
    try
      [transformedCode, transformedAST] = @transform wrappedCode, preNormalizationTransforms, @language.parse
      @ast = transformedAST
    catch error
      problemOptions = error: error, code: wrappedCode, codePrefix: @language.wrappedCodePrefix, reporter: @language.parserID, kind: error.index or error.id, type: 'transpile'
      @addProblem @createUserCodeProblem problemOptions
      return '' unless @language.parseDammit
      originalNodeRanges.splice()  # Reset any ranges we did find; we'll try again.
      try
        [transformedCode, transformedAST] = @transform wrappedCode, preNormalizationTransforms, @language.parseDammit
        @ast = transformedAST
      catch error
        problemOptions.kind = error.index or error.id
        problemOptions.reporter = 'acorn_loose' if @language.id is 'javascript'
        @addProblem @createUserCodeProblem problemOptions
        return ''

    # Now we've shed all the trappings of the original language behind; it's just JavaScript from here on.
    nodeGatherer = transforms.makeGatherNodeRanges originalNodeRanges, wrappedCode, @language.wrappedCodePrefix

    traversal.walkASTCorrect @ast, (node) =>
      nodeGatherer(node)
      if node.originalRange?
        startEndRangeArray = @language.removeWrappedIndent [node.originalRange.start, node.originalRange.end]
        node.originalRange =
          start: startEndRangeArray[0]
          end: startEndRangeArray[1]

    # TODO: return nothing, or the AST, and make sure CodeCombat can handle it returning nothing
    return rawCode

  transform: (code, transforms, parseFn) ->
    transformedCode = traversal.morphAST code, (_.bind t, @ for t in transforms), parseFn, @
    transformedAST = parseFn transformedCode, @
    [transformedCode, transformedAST]

  @getFunctionBody: (func) ->
    # Remove function() { ... } wrapper and any extra indentation
    source = if _.isString func then func else func.toString()
    return "" if source.trim() is "function () {}"
    source = source.substring(source.indexOf('{') + 2, source.lastIndexOf('}'))  #.trim()
    lines = source.split /\r?\n/
    indent = if lines.length then lines[0].length - lines[0].replace(/^ +/, '').length else 0
    (line.slice indent for line in lines).join '\n'

  convertToNativeType: (obj) ->
    # Convert obj to current language's equivalent type if necessary
    # E.g. if language is Python, JavaScript Array is converted to a Python list
    @language.convertToNativeType(obj)

  getStatementCount: ->
    count = 0
    if @language.usesFunctionWrapping()
      root = @ast.body[0].body # We assume the 'code' is one function hanging inside the program.
    else
      root = @ast.body

    #console.log(JSON.stringify root, null, '  ')
    traversal.walkASTCorrect root, (node) ->
      return if not node.type?
      return if node.userCode == false
      if node.type in [
        'ExpressionStatement', 'ReturnStatement', 'ForStatement', 'ForInStatement',
        'WhileStatement', 'DoWhileStatement', 'FunctionDeclaration', 'VariableDeclaration',
        'IfStatement', 'SwitchStatement', 'ThrowStatement', 'ContinueStatement', 'BreakStatement'
      ]
        ++count
    return count

self.Aether = Aether if self?
window.Aether = Aether if window?
self.esprima ?= esprima if self?
window.esprima ?= esprima if window?
