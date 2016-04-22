$Cypress.register "Connectors", (Cypress, _, $) ->

  returnFalseIfThenable = (key, args...) ->
    if key is "then" and _.isFunction(args[0]) and _.isFunction(args[1])
      ## https://github.com/cypress-io/cypress/issues/111
      ## if we're inside of a promise then the promise lib will naturally
      ## pass (at least) two functions to another cy.then
      ## this works similar to the way mocha handles thenables. for instance
      ## in coffeescript when we pass cypress commands within a Promise's
      ## .then() because the return value is the cypress instance means that
      ## the Promise lib will attach a new .then internally. it would never
      ## resolve unless we invoked it immediately, so we invoke it and
      ## return false then ensuring the command is not queued
      args[0]()
      return false

  Cypress.Cy.extend
    isCommandFromThenable: (cmd) ->
      args = cmd.get("args")

      cmd.get("name") is "then" and
        args.length is 3 and
          _.all(args, _.isFunction)

    isCommandFromMocha: (cmd) ->
      not cmd.get("next") and
        cmd.get("args").length is 2 and
          (cmd.get("args")[1].name is "done" or cmd.get("args")[1].length is 1)

  ## thens can return more "thenables" which are not resolved
  ## until they're 'really' resolved, so naturally this API
  ## supports nesting promises
  thenFn = (subject, options, fn) ->
    if _.isFunction(options)
      fn = options
      options = {}

    ## if this is the very last command we know its the 'then'
    ## called by mocha.  in this case, we need to defer its
    ## fn callback else we will not properly finish the run
    ## of our commands, which ends up duplicating multiple commands
    ## downstream.  this is because this fn callback forces mocha
    ## to continue synchronously onto tests (if for instance this
    ## 'then' is called from a hook) - by defering it, we finish
    ## resolving our deferred.
    current = @prop("current")
    if @isCommandFromMocha(current)
      return @prop("next", fn)

    _.defaults options,
      timeout: @_timeout()

    ## clear the timeout since we are handling
    ## it ourselves
    @_clearTimeout()

    remoteSubject = @getRemotejQueryInstance(subject)

    args = remoteSubject or subject
    args = if args?._spreadArray then args else [args]

    ## name could be invoke or its!
    name = @prop("current").get("name")

    cleanup = =>
      @stopListening @Cypress, "on:inject:command", returnFalseIfThenable

    @listenTo @Cypress, "on:inject:command", returnFalseIfThenable

    getRet = =>
      ret = fn.apply(@private("runnable").ctx, args)
      if (ret is @ or ret is @chain()) then null else ret

    Promise
    .try(getRet)
    .timeout(options.timeout)
    .then (ret) =>
      cleanup()

      ## if ret is null or undefined then
      ## resolve with the existing subject
      return ret ? subject
    .catch Promise.TimeoutError, =>
      @throwErr """
        cy.#{name}() timed out after waiting '#{options.timeout}ms'.\n
        Your callback function returned a promise which never resolved.\n
        The callback function was:\n
        #{fn.toString()}
      """, options._log

  invokeFn = (subject, fn, args...) ->
    @ensureParent()
    @ensureSubject()

    options = {}

    getMessage = ->
      if name is "invoke"
        ".#{fn}(" + Cypress.Utils.stringify(args) + ")"
      else
        ".#{fn}"

    ## name could be invoke or its!
    name = @prop("current").get("name")

    message = getMessage()

    options._log = Cypress.Log.command
      message: message
      $el: if Cypress.Utils.hasElement(subject) then subject else null
      onConsole: ->
        Subject: subject

    if not _.isString(fn)
      @throwErr("cy.#{name}() only accepts a string as the first argument.", options._log)

    fail = (prop) =>
      @throwErr("cy.#{name}() errored because the property: '#{prop}' does not exist on your subject.", options._log)

    failOnPreviousNullOrUndefinedValue = (previousProp, currentProp, value) =>
      @throwErr("cy.#{name}() errored because the property: '#{previousProp}' returned a '#{value}' value. You cannot call any properties such as '#{currentProp}' on a '#{value}' value.")

    failOnCurrentNullOrUndefinedValue = (prop, value) =>
      @throwErr("cy.#{name}() errored because your subject is currently: '#{value}'. You cannot call any properties such as '#{prop}' on a '#{value}' value.")

    getReducedProp = (str, subject) ->
      getValue = (memo, prop) ->
        switch
          when _.isString(memo)
            new String(memo)
          when _.isNumber(memo)
            new Number(memo)
          else
            memo

      _.reduce str.split("."), (memo, prop, index, array) ->

        ## if the property does not EXIST on the subject
        ## then throw a specific error message
        try
          fail(prop) if prop not of getValue(memo, prop)
        catch e
          ## if the value is null or undefined then it does
          ## not have properties which causes us to throw
          ## an even more particular error
          if _.isNull(memo) or _.isUndefined(memo)
            if index > 0
              failOnPreviousNullOrUndefinedValue(array[index - 1], prop, memo)
            else
              failOnCurrentNullOrUndefinedValue(prop, memo)
          else
            throw e
        return memo[prop]

      , subject

    getValue = =>
      remoteSubject = @getRemotejQueryInstance(subject)

      actualSubject = remoteSubject or subject

      prop = getReducedProp(fn, actualSubject)

      invoke = =>
        switch name
          when "its"
            prop
          when "invoke"
            if _.isFunction(prop)
              prop.apply(actualSubject, args)
            else
              @throwErr("Cannot call cy.invoke() because '#{fn}' is not a function. You probably want to use cy.its('#{fn}').", options._log)

      getFormattedElement = ($el) ->
        if Cypress.Utils.hasElement($el)
          Cypress.Utils.getDomElements($el)
        else
          $el

      value = invoke()

      if options._log
        options._log.set
          onConsole: ->
            obj = {}

            if name is "invoke"
              obj["Function"] = message
              obj["With Arguments"] = args if args.length
            else
              obj["Property"] = message

            _.extend obj,
              On:       getFormattedElement(actualSubject)
              Returned: getFormattedElement(value)

            obj

      return value

    ## wrap retrying into its own
    ## separate function
    retryValue = =>
      Promise
      .try(getValue)
      .catch (err) =>
        options.error = err
        @_retry(retryValue, options)

    do resolveValue = =>
      Promise.try(retryValue).then (value) =>
        @verifyUpcomingAssertions(value, options, {
          onRetry: resolveValue
        })

  Cypress.addChildCommand
    spread: (subject, options, fn) ->
      ## if this isnt an array blow up right here
      if not _.isArray(subject)
        @throwErr("cy.spread() requires the existing subject be an array!")

      subject._spreadArray = true

      thenFn.call(@, subject, options, fn)

  Cypress.addDualCommand

    then: ->
      thenFn.apply(@, arguments)

    ## making this a dual command due to child commands
    ## automatically returning their subject when their
    ## return values are undefined.  prob should rethink
    ## this and investigate why that is the default behavior
    ## of child commands
    invoke: ->
      invokeFn.apply(@, arguments)

    its: ->
      invokeFn.apply(@, arguments)