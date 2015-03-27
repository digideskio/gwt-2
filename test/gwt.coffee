async = require 'async'
bdd = require '../src'
sinon = require 'sinon'
assert = require 'assert'
Q = require 'q'
cbw = require 'cbw'

callAndPromise = (asyncFunction) ->
  return Q.denodeify(asyncFunction)()


describe 'bdd', ->
  describe 'with substitutions', ->
    feature = ->
      return declareStepsAndScenario
        steps:
          GIVEN: 'a condition ${condition}': sinon.spy ({condition}) ->
          WHEN: 'something is done ${action}': sinon.spy ({action}) ->
          THEN: 'I expect a result ${expectation}': sinon.spy ({expectation}) ->

        scenario: (runner) ->
          runner
            .given 'a condition ${condition}', condition: 'one'
            .when 'something is done ${action}', action: 'two'
            .then 'I expect a result ${expectation}', expectation: 'three'

    it 'should call `it` with description', (done) ->
      feature().run cbw(done) ({bddIt}) ->
        assert.equal bddIt.getCall(0).args[0],
          'Given a condition one, when something is done two, then I expect a result three'
        done()

    it 'should generate one test', (done) ->
      feature().run cbw(done) ({tests}) ->
        assert.equal tests.length, 1
        done()

    it 'should call GIVEN with substitution', (done) ->
      ({steps} = feature()).run cbw(done) ({tests}) ->
        assert steps.GIVEN['a condition ${condition}'].calledWith condition: 'one'
        done()

    it 'should call WHEN with substitution', (done) ->
      ({steps} = feature()).run cbw(done) ({tests}) ->
        assert steps.WHEN['something is done ${action}'].calledWith action: 'two'
        done()

    it 'should call THEN with substitution', (done) ->
      ({steps} = feature()).run cbw(done) ({tests}) ->
        assert steps.THEN['I expect a result ${expectation}'].calledWith expectation: 'three'
        done()


  describe 'with promises', ->
    feature = (onCalled) ->
      return declareStepsAndScenario
        steps:
          GIVEN: 'a condition ${condition}': ({condition}) ->
            return callAndPromise (cb) ->
              onCalled.given = true
              cb null
          WHEN: 'something is done ${action}': ({action}) ->
            return callAndPromise (cb) ->
              onCalled.when = true
              cb null
          THEN: 'I expect a result ${expectation}': ({expectation}) ->
            return callAndPromise (cb) ->
              onCalled.then = true
              cb null

        scenario: (runner) ->
          runner
            .given 'a condition ${condition}', condition: 'one'
            .when 'something is done ${action}', action: 'two'
            .then 'I expect a result ${expectation}', expectation: 'three'


    it 'should resolve GIVEN promise', (done) ->
      feature(onCalled = {}).run cbw(done) ->
        assert.equal onCalled.given, true
        done()

    it 'should resolve WHEN promise', (done) ->
      feature(onCalled = {}).run cbw(done) ->
        assert.equal onCalled.when, true
        done()

    it 'should resolve THEN promise', (done) ->
      feature(onCalled = {}).run cbw(done) ->
        assert.equal onCalled.then, true
        done()

  describe 'with resultTo', ->
    feature = (result1, result2) ->
      return declareStepsAndScenario
        steps:
          GIVEN: {}
          WHEN: 'something is done ${action}': ({@action}) ->
            return "(#{@action})"
          THEN: 'with the result': sinon.spy ({result1, result2}) ->
            assert.equal result1, "(two)"
            assert.equal result2, "(three)"

        scenario: (runner) ->
          runner
            .when('something is done ${action}', action: 'two').resultTo(result1)
            .when('something is done ${action}', action: 'three').resultTo(result2)
            .then 'with the result', ({result1, result2})

    it 'should resolve the result object before passing to the next step', (done) ->
      ({steps} = feature(result = bdd.result(), result2 = bdd.result())).run done

  describe 'combine()', ->
    features = ->
      feature1: declareStepsAndScenario
        steps:
          GIVEN: 'a condition ${condition}': sinon.spy ({@condition}) ->

        scenario: (runner) ->
          runner
            .given 'a condition ${condition}', condition: 'one'

      feature2: declareStepsAndScenario
        steps:
          WHEN: 'something is done ${action}': sinon.spy ({@action}) ->
            return "(#{@action})"

        scenario: (runner) ->
          runner
            .when('something is done ${action}', action: 'two')

      feature3: declareStepsAndScenario
        steps:
          THEN: 'something should have happened': sinon.spy ->

        scenario: (runner) ->
          runner
            .then 'something should have happened'

    it 'should run one step after the other', (done) ->
      ce = cbw done
      {feature1, feature2} = features()

      {steps: steps1} = feature1
      {steps: steps2} = feature2

      feature1.combine(feature2).run ce ->
        assert steps1.GIVEN['a condition ${condition}'].called, 'First feature steps not called'
        assert steps2.WHEN['something is done ${action}'].called, 'Second feature steps not called'
        done()

    it 'should run one set of steps after the other', (done) ->
      ce = cbw done
      {feature1, feature2, feature3} = features()

      {steps: steps1} = feature1
      {steps: steps2} = feature2
      {steps: steps3} = feature3

      feature1.combine(feature2, feature3).run ce ->
        assert steps1.GIVEN['a condition ${condition}'].called, 'First feature steps not called'
        assert steps2.WHEN['something is done ${action}'].called, 'Second feature steps not called'
        assert steps3.THEN['something should have happened'].called, 'Third feature steps not called'
        done()

    it 'should not execute promises more than once when features are reused', (done) ->
      ce = cbw done
      {feature1, feature2, feature3} = features()

      run1 = feature1.combine(feature2).combine(feature3)

      {steps: steps1} = feature1
      {steps: steps2} = feature2
      {steps: steps3} = feature3

      run1.run ce ->
        assert.equal steps1.GIVEN['a condition ${condition}'].callCount, 1
        assert.equal steps2.WHEN['something is done ${action}'].callCount, 1
        assert.equal steps3.THEN['something should have happened'].callCount, 1
        run1.run ce ->
          assert.equal steps1.GIVEN['a condition ${condition}'].callCount, 2
          assert.equal steps2.WHEN['something is done ${action}'].callCount, 2
          assert.equal steps3.THEN['something should have happened'].callCount, 2
          run1.run ce ->
            assert.equal steps1.GIVEN['a condition ${condition}'].callCount, 3
            assert.equal steps2.WHEN['something is done ${action}'].callCount, 3
            assert.equal steps3.THEN['something should have happened'].callCount, 3

            done()

    it 'should not execute promises more than once when features are reused', (done) ->
      ce = cbw done
      {feature1, feature2, feature3} = features()

      run1 = feature1.combine(feature2).combine(feature3)
      run2 = feature1.combine(feature2).combine(feature3)

      runX = run1.combine(run2)

      {steps: steps1} = feature1
      {steps: steps2} = feature2
      {steps: steps3} = feature3

      runX.run ce ->
        assert.equal steps1.GIVEN['a condition ${condition}'].callCount, 2
        assert.equal steps2.WHEN['something is done ${action}'].callCount, 2
        assert.equal steps3.THEN['something should have happened'].callCount, 2
        runX.run ce ->
          assert.equal steps1.GIVEN['a condition ${condition}'].callCount, 4
          assert.equal steps2.WHEN['something is done ${action}'].callCount, 4
          assert.equal steps3.THEN['something should have happened'].callCount, 4
          runX.run ce ->
            assert.equal steps1.GIVEN['a condition ${condition}'].callCount, 6
            assert.equal steps2.WHEN['something is done ${action}'].callCount, 6
            assert.equal steps3.THEN['something should have happened'].callCount, 6

            done()


  describe 'with context', ->
    feature = ->
      return declareStepsAndScenario
        steps:
          GIVEN: 'a condition ${condition}': ({@condition}) ->
          WHEN: 'something is done ${action}': ({@action}) ->
          THEN: 'I expect a result ${expectation}': ({@expectation}) ->

        scenario: (runner) ->
          runner
            .given 'a condition ${condition}', condition: 'one'
            .when 'something is done ${action}', action: 'two'
            .then 'I expect a result ${expectation}', expectation: 'three'
    # TODO unfinished



createTestContext = ->
  tests = []
  bddIt = sinon.spy (name, fn) ->
    tests.push fn

  run = ({runner}, cb) ->
    # Side effect: calls `it`, because `steps.done` is called inside scenario()
    runner.done it: bddIt

    async.series tests, cbw(cb) ->
      cb null, {bddIt, tests}

  return {bddIt, tests, run}


buildTestRunner = ({runner, steps}) ->
  assert runner, 'Runner not defined'
  assert steps

  return {
    steps
    runner

    run: (cb) ->
      {run} = createTestContext()

      run {runner}, cb

    combine: (suffixRunners...) ->
      return buildTestRunner {steps, runner: bdd.combine(runner, suffixRunners.map((s) -> s.runner)...)}
  }

declareStepsAndScenario = ({steps, scenario}) ->
  return buildTestRunner {steps, runner: scenario(bdd.accordingTo(-> steps).getRunner())}
