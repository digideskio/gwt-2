# TODO do promiseBuilder chaining at the very end, when done is called, because the composibility is
# broken.
Q = require 'q'
_ = require 'lodash'
assert = require 'assert'
I = require 'immutable'
uuid = require 'node-uuid'

# Prefix Result attributes, so that they don't clash with proxied attributes
# generated during resultTo()


hideAttributes = (object, keys...) ->
  attributes = {}

  keys.forEach (attr) ->
    if !Object.getOwnPropertyDescriptor(object, attr)
      Object.defineProperty object, attr,
        get: -> attributes[attr]
        set: (value) -> attributes[attr] = value

Keyword = ->
  id = uuid.v4()
  get: (object) ->
    hideAttributes(object, id)
    object[id]

  set: (object, value) ->
    hideAttributes(object, id)
    object[id] = value

withContext = (object, keyword, fn) ->
  if !keyword.get(object)
    keyword.set(object, {})

  fn.apply keyword.get(object)

proxyOnSelf = (container, object) ->
  keys = Object.keys(object or {})

  keys.forEach (key) ->
    Object.defineProperty container, key,
      get: -> object[key]
      enumerable: true
      configurable: true

  return keys


clearObjectProperties = (container, keys) ->
  for key in keys
    delete container[key]

class Result
  @kwContext = Keyword()

  constructor: (id, options = {}) -> withContext this, Result.kwContext, ->
    {@proxyResult} = options
    @id = id

    assert @id, 'Result id not given'
    @value = null

  getFromContext: (context) -> withContext this, Result.kwContext, ->
    return if @overriden then @value else context[@id]

  setInContext: (context, value) ->
    self = this
    withContext this, Result.kwContext, ->
      context[@id] = value
      if @proxyResult
        if typeof(value) is 'object' and !Array.isArray(value)
          if @proxyAttributeKeys
            clearObjectProperties self, @proxyAttributeKeys
          @proxyAttributeKeys = proxyOnSelf self, value

  set: (value) -> withContext this, Result.kwContext, ->
    @value = value
    @overriden = true

hasNestedResults = (result) ->
  for rkey, r of result
    if r instanceof Result then return true
  return false

buildGwt = ({options}) ->
  exports = {}

  assert options, 'Options object required'

  configOptions = options

  # Public configure method
  exports.configure = ({it: bddIt, proxyResult}) ->
    return buildGwt {
      options: _.extend({}, configOptions, {proxyResult: proxyResult ? configOptions.proxyResult, bddIt: configOptions.bddIt ? bddIt})
    }

  exports.result = makeResult = (id = uuid.v4()) ->
    return new Result(id, {proxyResult: configOptions.proxyResult})

  exports.combine = (leftRunner, rest...) ->
    assert leftRunner, 'left runner not defined'

    return (
      if !rest.length
        leftRunner
      else
        [rightRunner, rest...] = rest
        assert rightRunner, 'right runner not defined'

        exports.combine leftRunner.combine(rightRunner), rest...
    )

  exports.steps = (spec) ->
    return exports.accordingTo(-> spec).getRunner()

  exports.accordingTo = (spec) ->
    assert.equal typeof(spec), 'function', 'Spec must be a function'

    _getRunner = ({only} = {}) ->
      counts = getCounts spec()

      # Allow runner to be reused for multiple scenarios
      return {
        only: if not only then _getRunner(only: true)
        # Scenario must start with 'given'
        given: -> describeScenario(spec(), {only, counts}).given arguments...
        when: -> describeScenario(spec(), {only, counts}).when arguments...
        then: -> describeScenario(spec(), {only, counts}).then arguments...
        tap: -> describeScenario(spec(), {only, counts}).tap arguments...
        call: -> describeScenario(spec(), {only, counts}).call arguments...
        verifySpecHasBeenCovered: ->
          it 'Verify that all descriptions in the specification have been covered', ->
            uncovered = counts.getUncovered()

            for description in uncovered.GIVEN
              console.error 'Uncovered GIVEN:', description

            for description in counts.getUncovered().WHEN
              console.error 'Uncovered WHEN:', description

            for description in counts.getUncovered().THEN
              console.error 'Uncovered THEN:', description

            hasUncalled = uncovered.GIVEN.length > 0 or uncovered.WHEN.length > 0 or uncovered.THEN.length > 0
            assert !hasUncalled, "Has uncovered descriptions in specification. #{JSON.stringify uncovered}"
      }

    return getRunner: -> _getRunner()


  getCounts = (spec) ->
    keys =
      GIVEN: Object.keys(spec.GIVEN or {})
      THEN: Object.keys(spec.THEN or {})
      WHEN: Object.keys(spec.WHEN or {})
      TAP: Object.keys(spec.TAP or {})
      CALL: Object.keys(spec.TAP or {})

    counts = {GIVEN: {}, WHEN: {}, THEN: {}, TAP: {}}

    return {
      GIVEN: called: (description) ->
        counts.GIVEN[description] ?= 0
        counts.GIVEN[description]++
      WHEN: called: (description) ->
        counts.WHEN[description] ?= 0
        counts.WHEN[description]++
      THEN: called: (description) ->
        counts.THEN[description] ?= 0
        counts.THEN[description]++
      TAP: called: (description) ->
        counts.TAP[description] ?= 0
        counts.TAP[description]++
      CALL: called: (description) ->
        counts.TAP[description] ?= 0
        counts.TAP[description]++
      getUncovered: ->
        return {
          GIVEN: keys.GIVEN.filter (description) -> !counts.GIVEN[description]
          WHEN: keys.WHEN.filter (description) -> !counts.WHEN[description]
          THEN: keys.THEN.filter (description) -> !counts.THEN[description]
        }
    }

  isRunner = (fn) ->
    return fn?._isRunner

  buildDescription = (fullDescription = '') ->
    given: (rest, args) ->
      if fullDescription
        buildDescription "#{fullDescription}, and #{interpolate rest, args}"
      else
        buildDescription "Given #{interpolate rest, args}"
    when: (rest, args) ->
      buildDescription "#{fullDescription}, when #{interpolate rest, args}"
    then: (rest, args) -> buildDescription "#{fullDescription}, then #{interpolate rest, args}"
    get: -> fullDescription
    combine: (nextDescription) ->
      buildDescription "#{fullDescription}#{nextDescription.get()}"

  resolveResultArray = (context, args) ->
    argsCopy = _.clone args

    for i in [0...argsCopy.length]
      argsCopy[i] = resolveResultObject(context, argsCopy[i])

    return argsCopy

  resolveResultObject = (context, object) ->
    return (
      if object instanceof Result
        object.getFromContext(context)
      else if !object
        object
      else if typeof object isnt 'object'
        object
      else if object instanceof Date
        object
      else if object instanceof RegExp
        object
      else if Array.isArray(object)
        resolveResultArray(context, object)
      else
        objectCopy = _.clone object

        for key, result of objectCopy
          objectCopy[key] = resolveResultObject(context, result)

        objectCopy
    )

  crossCombineResults = makeResult()
  lastResult = makeResult()

  describeScenario = (spec, {only, counts}) ->
    {GIVEN, WHEN, THEN, DONE} = spec

    stepRunnerFactory = (name, collection) -> (description) ->
      fn = if typeof(description) isnt 'function' then collection[description] else description

      if !fn then throw new Error "'#{name}' doesn't contain '#{description}'"

      if isRunner(fn) then return fn

      return (context, extraContext, args) ->
        if !configOptions.sharedContext
          # Isolate from previous context.
          newContext = _.extend {}, context, extraContext
          newContext.updateContext()
        else
          newContext = _.extend context, extraContext

        # resolve promises contained in args. Use inplace replacement for the moment.
        resultWrapped = fn.apply newContext, resolveResultArray(crossCombineResults.getFromContext(context) ? {}, args)

        resultToUnwrap = if isRunner(resultWrapped) then {_runner: resultWrapped} else resultWrapped

        Q(resultToUnwrap).then (thenResult) ->
          result = if thenResult?._runner then thenResult._runner else thenResult

          nextStep = (result) ->
            # Pipe result to resultTo
            lastResult.setInContext(newContext, result)
            counts[name].called description
            # fn mutated context
            newContext

          if isRunner(result)
            result.run(world: newContext).then nextStep
          else if typeof result is 'function'
            Q.denodeify(result)().then nextStep
          else
            nextStep result

    getGiven = stepRunnerFactory 'GIVEN', GIVEN
    getWhen = stepRunnerFactory 'WHEN', WHEN
    getThen = stepRunnerFactory 'THEN', THEN
    getTap = stepRunnerFactory 'TAP'

    buildContext = ->
      if configOptions.sharedContext then return {}

      currentContext = null
      updateContext = -> currentContext = this
      return {getContext: (-> currentContext), updateContext}

    handlers = (done) ->
      finish: ->
        # TODO deprecate this or move
        done?()

      fail: (err) ->
        if done then return done err
        throw err

    buildPromiseChain = ({descriptionBuilder, promise, chain, multipleIt, bddIt}) ->
      if bddIt
        if multipleIt
          # Group into chains of non description..., description, non description...
          [chains, currentChain] = chain.reduce ([chains, currentChain, previousDescription], {thenFn, description}) ->
            assert.equal typeof thenFn, 'function'
            if description and previousDescription
              # A new chain group
              chains = chains.concat([currentChain])
              currentChain = []

            currentChain = currentChain.concat([{thenFn, description}])

            return [chains, currentChain, previousDescription or description]
          , [[], []]

          if currentChain.length
            chains = chains.concat([currentChain])

          if chains.length
            chains[chains.length - 1].push(thenFn: -> spec.done?())
          else
            chains = chains.concat([[thenFn: -> spec.done?()]])

          chains.forEach (chain, chainsIndex) ->
            bddIt "#{_.find(chain, (c) -> c.description)?.description ? ''}", (done) ->
              chain.forEach ({thenFn}) -> promise = promise.then(thenFn)
              promise
                .then(-> done())
                .fail(done)
              # Don't return promise, to remain compatible with protractor
              return
        else
          assert descriptionBuilder

          bddIt descriptionBuilder.get(), (done) ->
            chain.forEach ({thenFn}) -> promise = promise.then thenFn

            {finish, fail} = handlers done

            promise
              .then(-> spec.done?())
              .then(finish)
              .fail (err) ->
                spec.done?()
                fail err
              .fail fail

            # Don't return promise, to remain compatible with protractor
            return
      else
        chain.forEach ({thenFn}) -> promise = promise.then thenFn

        promise = promise
          .then(-> spec.done?())
          .fail((err) ->
            spec.done?()
            throw err)

        return promise

    promiseBuilderFactory = ({chain} = {chain:  I.List()}) ->
      return {
        then: ({thenFn, description}) ->
          return promiseBuilderFactory chain: chain.push {thenFn: thenFn, description}

        chain: chain

        combine: ({descriptionBuilder, promiseBuilder: rightPromiseBuilder}) ->
          thenFn = (context) ->
            if configOptions.sharedContext then return context

            newContext = buildContext()
            crossCombineResults.setInContext newContext, crossCombineResults.getFromContext context
            return newContext

          return promiseBuilderFactory chain: chain.push({thenFn}).concat(rightPromiseBuilder.chain)

        resolve: ({descriptionBuilder, bddIt, multipleIt}, context) ->
          bodyFn = ->
            assert descriptionBuilder

            deferred = Q.defer()
            deferred.resolve context
            return buildPromiseChain {promise: deferred.promise, chain, descriptionBuilder, bddIt, multipleIt}

          return bodyFn()
      }

    bdd = (descriptionBuilder, promiseBuilder, options) ->
      assert options, 'Must call bdd with options'
      assert promiseBuilder, 'bdd required promiseBuilder'

      {skippedUntilHere} = options

      run = (options, done) ->
        assert !done or typeof(done) is 'function', 'Done isnt a function'
        {bddIt, multipleIt, world} = options ? {}

        # run/done override config options
        bddIt ?= configOptions.bddIt

        # Default to multiple it blocks for a single runner
        multipleIt ?= configOptions.defaults?.multipleIt

        testBodyFn = ->
          return promiseBuilder.resolve({descriptionBuilder, bddIt, multipleIt}, world ? buildContext())

        if bddIt
          assert descriptionBuilder, '`bddIt` requires descriptionBuilder'
          assert !done, 'Done cannot be provided for `bddIt`'
          testBodyFn()
          return
        else
          {finish, fail} = handlers done
          runResult = testBodyFn()
            .then(finish)
            .then(-> spec.done?())
            .fail(fail)

          return runResult


      _isRunner: true

      # Used by combine for chaining
      promiseBuilder: promiseBuilder
      descriptionBuilder: descriptionBuilder
      skippedUntilHere: skippedUntilHere

      run: (args...) ->
        # run(options), run(options, cb), run(cb)
        assert !cb or typeof(cb) is 'function', 'Cb is not a function'

        options = {}
        cb = null

        if typeof args[0] is 'function'
          # run(cb)
          cb = args[0]
        else
          # run(options, cb), run(options)
          [options, cb] = args

        run options, cb

      resultTo: (result) ->
        bdd(descriptionBuilder,
          promiseBuilder.then description: '', thenFn: (context) ->
            results = crossCombineResults.getFromContext(context) ? {}
            lastResultValue = lastResult.getFromContext(context)

            if result instanceof Result
              assert result instanceof Result, 'Result must be created with bdd.result()'
              result.setInContext results, lastResultValue
            else if hasNestedResults(result)
              for rkey, r of result
                assert r instanceof Result, 'Subresult isnt bdd.result()'
                r.setInContext results, lastResultValue[rkey]
            else
              for key in Object.keys(result)
                delete result[key]

              _.extend result, lastResultValue

            crossCombineResults.setInContext context, results
            context
          options)

      given: (description, args...) ->
        expandedDescription = interpolate description, args
        given = getGiven(description)

        if isRunner(given)
          return @combine given

        bdd(descriptionBuilder.given(description, args),
          promiseBuilder.then description: "Given #{expandedDescription}", thenFn: (context) -> given context, {description: expandedDescription}, args
          options)

      when: (description, args...) ->
        expandedDescription = interpolate description, args
        whenFn = getWhen(description)

        if isRunner(whenFn)
          return @combine whenFn

        bdd(descriptionBuilder.when(description, args),
          promiseBuilder.then description: "when #{expandedDescription}", thenFn: (context) -> whenFn context, {description: expandedDescription}, args
          options)

      then: (description, args...) ->
        expandedDescription = interpolate description, args
        thenFn = getThen(description)

        if isRunner(thenFn)
          return @combine thenFn

        bdd(descriptionBuilder.then(description, args),
          promiseBuilder.then description: "then #{expandedDescription}", thenFn: (context) -> thenFn context, {description: expandedDescription}, args
          options)

      call: (fn, args...) ->
        bdd(descriptionBuilder,
          promiseBuilder.then description: '', thenFn: (context) -> getTap(fn) context, {}, args
          options)

      tap: (fn, args...) ->
        bdd(descriptionBuilder,
          promiseBuilder.then description: '', thenFn: (context) -> getTap(fn) context, {}, args
          options)

      combine: (rightBdd) ->
        assert rightBdd, 'right bdd not defined'

        if rightBdd.skippedUntilHere then return rightBdd

        newDescriptionBuilder = descriptionBuilder.combine(rightBdd.descriptionBuilder)

        return bdd(
          newDescriptionBuilder
          promiseBuilder.combine {
            descriptionBuilder: newDescriptionBuilder
            promiseBuilder: rightBdd.promiseBuilder
          }
          options)

      skipUntilHere: ->
        bdd(buildDescription(), promiseBuilderFactory(), _.extend {}, options, skippedUntilHere: true)

      done: ({multipleIt, world, it: bddIt} = {}) ->
        bddIt ?= configOptions.bddIt ? global.it
        bddIt = if only then bddIt.only.bind(bddIt) else bddIt

        run {descriptionBuilder, bddIt, multipleIt, world}

    return bdd(buildDescription(), promiseBuilderFactory(), {})

  interpolate = (description, args) ->
    kw = _.last(args)
    description.replace /[$]{([^}]*)}/g, (fullMatch, name, position, currentDescription) ->
      assert kw, "Keyword arguments not passed to spec description '#{description}'"
      kw[name]

  return exports

module.exports = (options) -> buildGwt(options: options)
