local gui = require('gui')
local persistence = require('persistence')
local time = require('time')
local util = require('util')

local numberSymbols = { '1️⃣', '2️⃣', '3️⃣', '4️⃣', '5️⃣', '6️⃣' }
local arrowSymbol = '➡️'


-- Persistent data setup

--persistent = {}

persistent = persistent or {}
persistent.state = persistent.state or 'introduction'
persistent.dailySentenceDelta = persistent.dailySentenceDelta or -1

-- Utilities

-- Renders dialog elements
local function renderDialog(rawArgs)
    local args = util.validateArguments(rawArgs,
        { name = 'text', type = 'string' },
        { name = 'subtext', type = 'string', required = false },
        { name = 'horizontalButtons', type = 'boolean', required = false },
        { name = 'buttons', type = 'table' }
    )

    gui.renderText({ text = args.text, subtext = args.subtext })
    gui.openGroup({ horizontal = args.horizontalButtons })

    for v in util.values(args.buttons) do
        gui.renderButton(v)
    end

    gui.closeGroup()
end

local function transitionState(state, stateRedirect, resetScroll)
    persistent.state = state

    if type(stateRedirect) == 'string' then
        persistent.stateRedirect = stateRedirect
    end

    persistence.commit()
    gui.render({ resetScroll = resetScroll })
    persistence.commit()
end

-- A button handler to persist data and transition to a specified dialog, optionally executing `pre`
local function stateTransitionHandler(state, pre, allowRedirect, stateRedirect)
    return function()
        if type(pre) == 'function' then
            pre()
        end

        if allowRedirect and type(persistent.stateRedirect) == 'string' then
            state = persistent.stateRedirect
            persistent.stateRedirect = nil
        end

        transitionState(state, stateRedirect)
    end
end

-- Constructs a state with a single dialog
local function constructDialogState(rawArgs)
    local args = util.validateArguments(rawArgs,
        { name = 'table', type = 'table', required = false }, -- table to store the value in under the index `variable`
        { name = 'variable', required = false }, -- the index to store the value under in table `table`
        { name = 'text', type = 'string' }, -- large text formatted with <h4>
        { name = 'subtext', type = 'string', required = false }, -- unformatted text shown below `text`
        { name = 'horizontalButtons', type = 'boolean', required = false },
        { name = 'buttons', type = 'table' } -- the buttons to display, see below
    )
    local buttons = util.map(args.buttons, function(k, v)
        local button = util.validateArguments(v,
            { name = 'text', type = 'string' },
            { name = 'state', type = 'string' },
            { name = 'value', required = false },
            { name = 'allowRedirect', type = 'boolean', required = false },
            { name = 'stateRedirect', type = 'string', required = false }
        )
        return k, {
            width = 'matchParent',
            text = button.text,
            handler = stateTransitionHandler(button.state, function()
                if args.table ~= nil and args.variable ~= nil then
                    args.table[args.variable] = button.value
                end
            end, button.allowRedirect, button.stateRedirect)
        }
    end)

    return function()
        renderDialog({
            text = args.text,
            subtext = args.subtext,
            horizontalButtons = args.horizontalButtons,
            buttons = buttons
        })
    end
end

local function getFollowingDailyTaskResetInstant(now)
    local now = now or time.getCurrentInstant()
    local instant = util.shallowCopy(now)
    instant.millisecondOfSecond = 0
    instant.secondOfMinute = 0
    instant.minuteOfHour = 0
    instant.hourOfDay = 3

    if time.compareInstants(instant, now) < 0 then
        instant = time.shiftInstantBy(instant, { days = 1 })
    end

    return instant
end

local function getNotificationIdRender()
    return 'render'
end

-- Used to invoke `render` only once after processing a batch of notifications
local function scheduleNotificationRender()
    time.scheduleNotificationAfter({
        id = getNotificationIdRender(),
        duration = {},
        data = { type = 'render' }
    })
end

local function getTaskCompletionNotificationId(taskId)
    return taskId..'TaskCompletion'
end

local function getTaskCooldownNotificationId(taskId)
    return taskId..'TaskCooldown'
end

local function isTaskBeingCompleted(taskId)
    return time.getNotification(getTaskCompletionNotificationId(taskId)) ~= nil
end

local function isTaskOnCooldown(taskId)
    return time.getNotification(getTaskCooldownNotificationId(taskId)) ~= nil
end

local function hasTaskBeenCompleted(taskId)
    return (not isTaskBeingCompleted(taskId)) and isTaskOnCooldown(taskId)
end

local function isTaskCancellable(taskId)
    local completionNotification = time.getNotification(getTaskCompletionNotificationId(taskId))
    local cooldownNotification = time.getNotification(getTaskCooldownNotificationId(taskId))

    if completionNotification ~= nil then
        return completionNotification.data.task
    elseif cooldownNotification ~= nil then
        return cooldownNotification.data.task
    else
        return nil
    end
end

local function cancelTaskIfPossible(taskId)
    local cancellableTask = isTaskCancellable(taskId)

    if cancellableTask then
        local completionTask = time.cancelNotification(getTaskCompletionNotificationId(taskId))
        time.cancelNotification(getTaskCooldownNotificationId(taskId))

        if not completionTask then -- days already subtracted, revert
            persistent.daysRemaining = persistent.daysRemaining + cancellableTask.subtractedDays
        end

        return true
    else
        return false
    end
end

--[[
 @param `taskId`             The unique ID of the task;
 @param `subtractedDays`     Number of days to subtract
 @param `completionDuration` The cooldown time the user must wait to complete the task again, `false` or `nil` to
                             complete immediately, or `true` to wait until midnight
 @param `oncePerDay`         If `completionDuration` is a duration, `oncePerDay` limits the possibility to fulfill this
                             task more than once per day
 ]]
local function startCompletingTask(taskId, subtractedDays, completionDuration, oncePerDay)
    local oncePerDay = ((not not oncePerDay) and (type(completionDuration) == 'table'))
                        or (type(completionDuration) ~= 'table')
    local now = time.getCurrentInstant()
    local completionAt, cooldownResetAt

    if type(completionDuration) == 'table' then
        completionAt = time.shiftInstantBy(now, completionDuration)
    elseif type(completionDuration) == 'boolean' and completionDuration then
        completionAt = getFollowingDailyTaskResetInstant(now)
    else
        completionAt = now
    end

    if oncePerDay then
        cooldownResetAt = getFollowingDailyTaskResetInstant(now)
    else
        cooldownResetAt = nil
    end

    local task = {
        id = taskId,
        startAt = now,
        subtractedDays = subtractedDays,
        completionAt = completionAt,
        cooldownResetAt = cooldownResetAt,
    }

    time.scheduleNotificationAt({
        id = getTaskCompletionNotificationId(taskId),
        instant = completionAt,
        data = {
            type = 'taskCompletion',
            task = task,
        },
    })

    if cooldownResetAt then
        time.scheduleNotificationAt({
            id = getTaskCooldownNotificationId(taskId),
            instant = cooldownResetAt,
            data = {
                type = 'taskCooldown',
                task = task,
            },
        })
    end
end

local function renderItem(args)
    gui.openGroup({
        id = args.id,
        enabled = args.enabled,
        opacity = args.opacity,
        horizontal = true,
        margin = 0,
        padding = { horizontal = 24 },
        handler = args.handler,
        background = args.background,
    })
    gui.renderText({
        id = (function() if args.id then return args.id..'IconStart' else return nil end end)(),
        enabled = args.enabled,
        text = '<big><big>'..(args.iconStart or ' ')..'</big></big>',
        weight = 0.0,
        gravity = { 'start', 'centerVertical' },
        margin = 0,
        width = 'wrapContent',
        height = 'matchParent',
    })
    gui.renderText({
        id = (function() if args.id then return args.id..'Text' else return nil end end)(),
        enabled = args.enabled,
        text = args.text,
        subtext = args.subtext,
        weight = 1.0,
        gravity = { 'start', 'centerVertical' },
        margin = 0,
        width = 'wrapContent',
        height = 'matchParent',
    })
    gui.renderText({
        id = (function() if args.id then return args.id..'IconEnd' else return nil end end)(),
        enabled = args.enabled,
        text = '<big><big>'..(args.iconEnd or ' ')..'</big></big>',
        weight = 0.0,
        gravity = { 'end', 'centerVertical' },
        margin = 0,
        width = 'wrapContent',
        height = 'matchParent',
    })
    gui.closeGroup()
end

--[[
 @param `taskId`
 @param `toyKind`
 ]]
local function constructToyTask(args)
    return function()
        local persistentField = 'toyTask-'..args.taskId
        local suitableToys = util.sort(
            util.filter(
                persistent.toys,
                function(_, toy) return toy[args.toyKind] end
            ),
            function(a, b) return a.diameter - b.diameter end
        )

        if #suitableToys <= 0 then
            gui.renderText({
                text = 'No suitable toy found for this task. Please, add one in the settings.'
            })
            gui.renderText({ text = 'Back', padding = { vertical = 32 }, gravity = 'center', handler = stateTransitionHandler('main') })
        else
            persistent[persistentField] = persistent[persistentField] or 0

            if persistent[persistentField] > #suitableToys then
                persistent[persistentField] = #suitableToys
            end

            gui.renderText({
                text = args.text
            })
            gui.renderNumberPicker({
                value = persistent[persistentField],
                minValue = 1,
                maxValue = #suitableToys,
                width = 'matchParent',
                formatter = function(toyIndex)
                    local toy = suitableToys[toyIndex]

                    return toy.description..', -'..toy.diameter..' days'
                end,
                handler = function(newValue)
                    persistent[persistentField] = newValue
                end
            })
            gui.openGroup({ horizontal = true })
            gui.renderButton({
                text = 'Cancel',
                handler = stateTransitionHandler('main'),
            })
            gui.renderButton({
                text = args.buttonText,
                handler = function()
                    startCompletingTask(args.taskId, persistent[persistentField], args.completionDuration, args.oncePerDay)
                    transitionState('main')
                end
            })
            gui.closeGroup()
        end
    end
end

local function getRollDelayMillis(remainingAnimationTasks)
    return math.pow(1.0 / 1.2, remainingAnimationTasks - 1) * 1000
end

-- States
local states = {
    introduction = function()
        gui.renderText({
            text = [[
                This is a long-term roulette aimed to make you learn to orgasm from anal.
                There are no required daily tasks, but you have to earn the ability to orgasm form penile stimulation.
                During this roulette, you must be locked in a chastity cage, unless the current <i>days remaining</i> count is 0 or lower.
                Every day, the <i>days remaining</i> count will be automatically decremented by one.
                You can also lower the <i>days remaining</i> count by completing optional daily tasks.
                The more orgasms you have, the longer you will have to wait for the next one.
            ]]
        })

        gui.renderButton({ text = 'Continue', width = 'matchParent', handler = stateTransitionHandler('deviceDialog') })
    end,
    deviceDialog = constructDialogState({
        table = persistent,
        variable = 'deviceOwned',
        text = 'Do you own a <b>chastity device</b>?',
        subtext = 'This setting may be changed later.',
        horizontalButtons = true,
        buttons = {
            {
                text = 'Yes',
                state = 'difficultyDialog',
                allowRedirect = true,
                value = true
            },
            {
                text = 'No',
                state = 'deviceNotOwnedResponse',
                allowRedirect = false,
                value = false
            }
        }
    }),
    deviceNotOwnedResponse = constructDialogState({
        text = [[
            If you do not own a chastity cage or are not able to wear one, that is fine, but you must follow these rules:
            <ul>
                <li>you <b>must not</b> touch your penis at all;</li>
                <li>you <b>must not</b> stimulate your penis by pressure or friction <b>in any way</b>;</li>
                <li>any violations of these rules must be reported, and you will be punished depending on the severity of the violations</li>
            </ul>
        ]],
        buttons = {
            {
                text = 'I agree',
                state = 'difficultyDialog',
                allowRedirect = true
            }
        }
    }),
    difficultyDialog = constructDialogState({
        table = persistent,
        variable = 'difficulty',
        text = [[
            Choose your <b>difficulty</b>. The more difficult, the more additional days you will have to endure in chastity
            after being locked back in.
        ]],
        subtext = 'This setting may be changed later.',
        buttons = {
            {
                text = 'Casual (+1 day)',
                state = 'orgasmDenialDialog',
                allowRedirect = true,
                value = 1
            },
            {
                text = 'Regular (+2 days)',
                state = 'orgasmDenialDialog',
                allowRedirect = true,
                value = 2
            },
            {
                text = 'Serious (+3 days)',
                state = 'orgasmDenialDialog',
                allowRedirect = true,
                value = 3
            }
        }
    }),
    orgasmDenialDialog = constructDialogState({
        table = persistent,
        variable = 'variantOrgasmDenial',
        text = [[
            Do you enjoy <b>orgasm denial</b>? If you enable this variant,
            50% of the time you are let out of chastity, you will not be allowed to have an orgasm.
        ]],
        subtext = 'This setting may be changed later.',
        horizontalButtons = true,
        buttons = {
            {
                text = 'Yes',
                state = 'cumEatingDialog',
                allowRedirect = true,
                value = true
            },
            {
                text = 'No',
                state = 'cumEatingDialog',
                allowRedirect = true,
                value = false
            }
        }
    }),
    cumEatingDialog = constructDialogState({
        table = persistent,
        variable = 'variantCumEating',
        text = [[
            Do you enjoy <b>cum eating</b>? If you enable this variant,
            most of the time you have an orgasm, you will have to eat your cum.
        ]],
        subtext = 'This setting may be changed later.',
        horizontalButtons = true,
        buttons = {
            {
                text = 'Yes',
                state = 'toysDialog',
                allowRedirect = true,
                value = true
            },
            {
                text = 'No',
                state = 'toysDialog',
                allowRedirect = true,
                value = false
            }
        }
    }),
    toysDialog = function()
        persistent.toysDialogTmp = persistent.toysDialogTmp or {}
        persistent.toysDialogTmp.addToyDescription = persistent.toysDialogTmp.addToyDescription or ''
        persistent.toysDialogTmp.addToyOral = persistent.toysDialogTmp.addToyOral or false
        persistent.toysDialogTmp.addToyAnal = persistent.toysDialogTmp.addToyAnal or false
        persistent.toysDialogTmp.addToyPlug = persistent.toysDialogTmp.addToyPlug or false
        persistent.toysDialogTmp.addToyDiameter = persistent.toysDialogTmp.addToyDiameter or 2

        if persistent.toys == nil then
            persistent.toys = {}
        end

        gui.renderText({
            text = 'What toys do you own?',
            subtext = [[
                Please, specify which toys you own, so they can be used to fulfill certain tasks. Do not add toys which
                are not safe to use or which are not made for the purpose of being used as intimate toys.
            ]]
        })
        gui.openGroup()
        gui.renderText({ text = "Add toy" })
        gui.renderText({ subtext = "Toy description" })
        gui.renderTextInput({
            text = persistent.toysDialogTmp.addToyDescription,
            handler = function(text)
                persistent.toysDialogTmp.addToyDescription = text
            end,
        })
        gui.renderText({ subtext = "Possible usage of the toy" })
        gui.renderCheckBox({
            text = 'Oral tasks (sucking, deepthroating)',
            checked = persistent.toysDialogTmp.addToyOral,
            handler = function(checked)
                persistent.toysDialogTmp.addToyOral = checked
            end
        })
        gui.renderCheckBox({
            text = 'Anal tasks (fucking)',
            checked = persistent.toysDialogTmp.addToyAnal,
            handler = function(checked)
                persistent.toysDialogTmp.addToyAnal = checked
            end
        })
        gui.renderCheckBox({
            text = 'Butt Plug (for long-term wear)',
            checked = persistent.toysDialogTmp.addToyPlug,
            handler = function(checked)
                persistent.toysDialogTmp.addToyPlug = checked
            end
        })
        gui.renderText({ subtext = "Maximum diameter of the toy" })
        gui.renderNumberPicker({
            value = persistent.toysDialogTmp.addToyDiameter,
            minValue = 1,
            maxValue = 10,
            width = 'matchParent',
            formatter = function(value)
                local string = tostring(value)..' cm'

                if value >= 10 then
                    string = string.." (Please, this can't be healthy)"
                end

                return string
            end,
            handler = function(value)
                persistent.toysDialogTmp.addToyDiameter = value
            end
        })
        gui.renderButton({
            text = 'Add toy',
            width = 'matchParent',
            handler = function()
                if persistent.toysDialogTmp.addToyDescription:gsub("%s+", "") == ""
                    or not (persistent.toysDialogTmp.addToyOral or persistent.toysDialogTmp.addToyAnal or persistent.toysDialogTmp.addToyPlug) then
                    -- invalid toy
                    return
                end

                table.insert(persistent.toys, {
                    description = persistent.toysDialogTmp.addToyDescription,
                    oral = persistent.toysDialogTmp.addToyOral,
                    anal = persistent.toysDialogTmp.addToyAnal,
                    plug = persistent.toysDialogTmp.addToyPlug,
                    diameter = persistent.toysDialogTmp.addToyDiameter,
                })

                persistent.toysDialogTmp = nil

                transitionState('toysDialog', false)
            end
        })
        gui.closeGroup()
        gui.openGroup()
        gui.renderText({ text = 'Added toys' })

        if #persistent.toys == 0 then
            gui.renderText({ subtext = 'No toys have been added, yet. Add them using the form below.' })
        else
            for toyIndex, toy in ipairs(persistent.toys) do
                gui.openGroup({ horizontal = true })

                local subtext = ''

                if (toy.oral) then if subtext:len() > 0 then subtext = subtext..', ' end subtext = subtext..'oral' end
                if (toy.anal) then if subtext:len() > 0 then subtext = subtext..', ' end subtext = subtext..'anal' end
                if (toy.plug) then if subtext:len() > 0 then subtext = subtext..', ' end subtext = subtext..'plug' end

                subtext = 'Diameter: '..tostring(toy.diameter)..' cm; '..subtext

                gui.renderText({
                    text = toy.description,
                    subtext = subtext,
                    weight = 1
                })
                gui.renderButton({
                    text = string.char(0xE2, 0x9D, 0x8C), -- cross mark emoji
                    weight = 0,
                    handler = function()
                        table.remove(persistent.toys, toyIndex)
                        transitionState('toysDialog', false)
                    end
                })
                gui.closeGroup()
            end
        end

        gui.closeGroup()
        gui.renderButton({
            text = 'Finish adding toys',
            width = 'matchParent',
            handler = stateTransitionHandler('main', function()
                persistent.toysDialogTmp = nil
            end, true)
        })
    end,
    settings = function()
        gui.renderText({
            text = 'Chastity device',
            subtext = (function() if persistent.deviceOwned then return 'Enabled' else return 'Disabled' end end)(),
            handler = stateTransitionHandler('deviceDialog', nil, false, 'settings')
        })
        gui.renderText({
            text = 'Difficulty',
            subtext = (function() if persistent.difficulty == 1 then return '+1 day' else return  '+'..tostring(persistent.difficulty)..' days' end end)(),
            handler = stateTransitionHandler('difficultyDialog', nil, false, 'settings')
        })
        gui.renderText({
            text = 'Orgasm denial variant',
            subtext = (function() if persistent.variantOrgasmDenial then return 'Enabled' else return 'Disabled' end end)(),
            handler = stateTransitionHandler('orgasmDenialDialog', nil, false, 'settings')
        })
        gui.renderText({
            text = 'Cum eating variant',
            subtext = (function() if persistent.variantCumEating then return 'Enabled' else return 'Disabled' end end)(),
            handler = stateTransitionHandler('cumEatingDialog', nil, false, 'settings')
        })
        gui.renderText({
            text = 'Toys',
            subtext = tostring(#persistent.toys)..' toys registered',
            handler = stateTransitionHandler('toysDialog', nil, false, 'settings')
        })
        gui.renderText({ text = 'Back', padding = { vertical = 32 }, gravity = 'center', handler = stateTransitionHandler('main') })
    end,
    taskClothing = function()
        persistent.taskClothingArticles = persistent.taskClothingArticles or 1
        gui.renderText({
            text = 'Wear an article of feminine clothing the entire day, possibly hidden under regular clothes:'
        })
        gui.renderNumberPicker({
            value = persistent.taskClothingArticles,
            minValue = 1,
            width = 'matchParent',
            formatter = function(value)
                if value == 1 then
                    return '1 article, -1 day'
                else
                    return value..' articles, -'..value..' days'
                end
            end,
            handler = function(newValue)
                persistent.taskClothingArticles = newValue
            end
        })
        gui.openGroup({ horizontal = true })
        gui.renderButton({
            text = 'Cancel',
            handler = stateTransitionHandler('main'),
        })
        gui.renderButton({
            text = 'Begin task',
            handler = function()
                startCompletingTask('clothing', persistent.taskClothingArticles, true)
                transitionState('main')
            end
        })
        gui.closeGroup()
    end,
    taskOralDeepMultiple = constructToyTask({
        taskId = 'oralDeepMultiple',
        toyKind = 'oral',
        text = 'Do 10 deepthroats without your teeth touching the dildo',
        buttonText = 'Finish task',
        completionDuration = nil,
        oncePerDay = true,
    }),
    taskOralDeepHold = constructToyTask({
        taskId = 'oralDeepHold',
        toyKind = 'oral',
        text = 'Hold a deepthroat for 10 seconds without your teeth touching the dildo',
        buttonText = 'Finish task',
        completionDuration = nil,
        oncePerDay = true,
    }),
    taskAnalMasturbation = constructToyTask({
        taskId = 'analMasturbation',
        toyKind = 'anal',
        text = 'Anally masturbate with a toy for at least 15 minutes',
        buttonText = 'Begin task',
        completionDuration = { minutes = 15 },
        oncePerDay = true,
    }),
    taskAnalPlug = constructToyTask({
        taskId = 'analPlug',
        toyKind = 'plug',
        text = 'Wear a buttplug, use long-lasting lubricant, removal allowed for hygienic purposes',
        buttonText = 'Begin task',
        completionDuration = { hours = 11 },
        oncePerDay = false,
    }),
    main = function()
        -- Ensure state is initialized
        if persistent.score == nil then
            persistent.score = 0
            persistent.chastitySentence = persistent.difficulty
            persistent.daysRemaining = persistent.chastitySentence
        end

        -- Rendering
        local function renderTaskGeneral(taskId, iconStart, text, handler, completionDuration, oncePerDay)
            local subtext

            if type(completionDuration) == 'table' then
                subtext = 'Completion: After '
                local first = true

                for field in util.values(time.getDurationFields()) do
                    if type(completionDuration[field]) == 'number' and completionDuration[field] ~= 0 then
                        if not first then
                            subtext = subtext..', '
                        end

                        local unit -- a unit in its singular or plural form

                        if completionDuration[field] == 1 then
                            unit = string.sub(field, 1, -2)
                        else
                            unit = field
                        end

                        subtext = subtext..completionDuration[field]..' '..unit
                        first = false
                    end
                end
            elseif type(completionDuration) == 'boolean' and completionDuration then
                subtext = 'Completion: At midnight'
            else
                subtext = 'Completion: Immediate'
            end

            local oncePerDay = ((not not oncePerDay) and (type(completionDuration) == 'table'))
                    or (type(completionDuration) ~= 'table')
            subtext = subtext..'<br>Cooldown: '

            if oncePerDay then
                subtext = subtext..'Until midnight'
            else
                subtext = subtext..'Immediate'
            end

            local iconStart = iconStart or '⚫'
            local iconEnd

            if hasTaskBeenCompleted(taskId) then
                iconEnd = '✔️'
            elseif isTaskBeingCompleted(taskId) then
                iconEnd = '✅'
            else
                iconEnd = '◻️'
            end

            renderItem({
                text = text,
                subtext = subtext,
                iconStart = iconStart,
                iconEnd = iconEnd,
                handler = function()
                    if false and isTaskOnCooldown(taskId) and not isTaskCancellable(taskId) then
                        return
                    end

                    if cancelTaskIfPossible(taskId) then
                        transitionState('main', false)
                    else
                        handler(taskId, completionDuration, oncePerDay)
                    end
                end,
            })
        end

        local function renderTaskSimple(taskId, iconStart, text, subtractedDays, completionDuration, oncePerDay)
            renderTaskGeneral(taskId, iconStart, text, function()
                startCompletingTask(taskId, subtractedDays, completionDuration, oncePerDay)
                transitionState('main', false)
            end, completionDuration, oncePerDay)
        end

        gui.renderText({ text = '<b><big>Chastity</big></b>' })

        if persistent.daysRemaining > 0 then
            renderItem({
                text = (function()
                    if persistent.daysRemaining == 1 then
                        return '1 day remaining'
                    else
                        return tostring(persistent.daysRemaining)..' days remaining'
                    end
                end)(),
                subtext = 'out of the original '..tostring(persistent.chastitySentence)..'-day sentence',
                iconStart = '🔒',
            })
        else
            renderItem({
                text = '<b>Chastity sentence completed</b>',
                subtext = '<b>Tap to request to be unlocked</b>',
                iconStart = '🔐',
                iconEnd = '✔️',
                handler = stateTransitionHandler('requestUnlock'),
            })
        end

        gui.renderText({ text = '<b><big>Optional daily tasks</big></b>' })
        gui.renderText({ text = '<b>Appearance</b>' })
        renderTaskSimple('shave', '🛁️', 'Shave your entire body', 1)
        renderTaskGeneral('clothing', '👙', 'Wear feminine clothing, possibly hidden under clothes', stateTransitionHandler('taskClothing'), true)
        renderTaskSimple('lipstick', '💄', 'Apply chapstick or lipstick 3 times today', 1)
        renderTaskSimple('makeup', '😘', 'Apply cute, light makeup for at least an hour', 1, { hours = 1 }, true)
        renderTaskSimple('paintedToenails', '💅', 'Have flawlessly painted toenails', 1, true)
        renderTaskSimple('paintedFingernails', '💅', 'Have flawlessly painted fingernails', 1, true)
        renderTaskSimple('selfie', '🤳', 'Take a selfie and leave it on your phone for at least a week', 1)
        renderTaskSimple('nightwear', '💤', 'Sleep in feminine underwear only or feminine nightwear only', 1, true)
        gui.renderText({ text = '<b>Exercise</b>' })
        gui.renderText({ text = '<b>Oral</b>' })
        renderTaskSimple('oralShallow', '💋', 'Suck a dildo for at least 15 minutes, use lubricant, do your best', 1, { minutes = 15 }, true)
        renderTaskGeneral('oralDeepMultiple', '👅', 'Do 10 deepthroats without your teeth touching the dildo', stateTransitionHandler('taskOralDeepMultiple'))
        renderTaskGeneral('oralDeepHold', '👄', 'Hold a deepthroat for 10 seconds without your teeth touching the dildo', stateTransitionHandler('taskOralDeepHold'))
        gui.renderText({ text = '<b>Anal</b>' })
        renderTaskSimple('enema', '🚿', 'Take a shallow, 200 ml enema, possibly more times, so that your colon is clean', 1)
        renderTaskGeneral('analMasturbation', '🍆', 'Anal masturbation for at least 15 minutes', stateTransitionHandler('taskAnalMasturbation'), { minutes = 15 }, true)
        renderTaskSimple('analOrgasm', '💦', 'Have an orgasm from anal masturbation only', 7)
        renderTaskGeneral('analPlug', '♠️', 'Wear a buttplug, use long-lasting lubricant, removal allowed for hygienic purposes', stateTransitionHandler('taskAnalPlug'), { hours = 11 })
        gui.renderText({ text = '<b><big>Other</big></b>' })
        renderItem({
            iconStart = '⚙️',
            text = '️Settings',
            handler = stateTransitionHandler('settings'),
        })
    end,
    requestUnlock = function()
        local function renderRollDialog(args)
            local enabled = not not args.enablePredicate()
            local textOpacity = (function() if enabled then return 1.0 else return 0.5 end end)()

            gui.renderText({
                text = '<big>'..args.text..'</big>',
                subtext = args.subtext,
                opacity = textOpacity,
            })

            for i = 1, 6 do
                local icon
                local background

                if persistent.requestUnlock[args.id] == i then
                    icon = arrowSymbol

                    if persistent.requestUnlock[args.id..'Finished'] then
                        background = 0x7F39C2FE
                    else
                        background = nil
                    end
                else
                    icon = numberSymbols[i]
                    background = nil
                end

                renderItem({
                    id = args.rollIdPrefix..tostring(i),
                    iconStart = icon,
                    text = args.rolls[i],
                    background = background,
                    opacity = textOpacity,
                })
            end

            if persistent.requestUnlock[args.id..'Finished']
                    and args.rollFinishMessages
                    and args.rollFinishMessages[persistent.requestUnlock[args.id]] then
                gui.renderText({
                    text = args.rollFinishMessages[persistent.requestUnlock[args.id]]
                })
            end

            gui.renderButton({
                id = args.id..'Button',
                width = 'matchParent',
                text = '<big>🎲</big> Roll task',
                enabled = (not persistent.requestUnlock[args.id]) and enabled,
                handler = function()
                    gui.updateElement({
                        id = args.id..'Button',
                        data = { enabled = false },
                    })

                    persistent.requestUnlock[args.id] = math.random(1, 6)
                    local animationTasks = 6 * 10 + math.random(1, 6 * 3)
                    local firstRollToUpdate = ((persistent.requestUnlock[args.id] - animationTasks + 1 - 1) % 6) + 1

                    time.scheduleNotificationAfter({
                        id = args.id,
                        duration = { milliseconds = getRollDelayMillis(animationTasks) },
                        data = {
                            type = 'rollAnimation',
                            rollIdPrefix = args.rollIdPrefix,
                            rollToUpdate = firstRollToUpdate,
                            remainingAnimationTasks = animationTasks - 1,
                        },
                    })

                    persistence.commit()
                end
            })
        end

        persistent.requestUnlock = persistent.requestUnlock or {}

        gui.renderText({
            text = 'Congratulations, you made it! I am so proud of you! Here is your reward.'
        })

        local orgasmDenialRollNoUnlock = {
            unlock = false,
            orgasm = false,
            text = 'Denied, no unlocking',
            rollFinishMessage = [[
                It seems like you will not get to unlock your chastity device just yet.
                I know you have enjoyed being locked so far, I am sure you can endure it until next time.
                Either way, you have no choice; the device stays on. Let's hope you are not as unlucky next time.
                <br>
                I am sure you have some pent up frustration you are aching to release. Maybe you should consider anal
                masturbation instead.
            ]],
        }
        local orgasmDenialRollNoOrgasm = {
            unlock = true,
            orgasm = false,
            text = 'You may masturbate for up to 30 minutes, but you must not have an orgasm',
            rollFinishMessage = [[
                Go ahead and unlock your chastity device. You can masturbate, but you must not have an orgasm from
                stimulating your penis. When you are done, you can, however, lock yourself back up and enjoy anal
                masturbation. Maybe you can reach an anal orgasm instead.
                <br>
                Remember: Do not reach an orgasm of any kind
                while you are unlocked.
            ]]
        }
        local orgasmDenialRollRuinedOrgasm = {
            unlock = true,
            orgasm = true,
            text = 'Have a ruined orgasm (stop masturbating 2 seconds before having an orgasm)',
            rollFinishMessage = [[
                Finally some release, I am sure you have been looking forward to this. Go ahead and unlock your chastity
                device and masturbate. Before you reach an orgasm, though, make sure to ruin it. That is, stop
                masturbating at least 2 seconds before having the orgasm. Do not touch your penis for 1 minute after
                having the orgasm.
                <br>
                Remember: No more than one orgasm.
            ]]
        }
        local orgasmDenialRollFullOrgasm = {
            unlock = true,
            orgasm = true,
            text = 'Have a full orgasm',
            rollFinishMessage = [[
                It's your lucky day! Go grab that key, unlock your chastity device and enjoy getting off!
                You have earned it! Make sure to really enjoy it, because once you are done, you will be putting that
                chastity device on again.
                <br>
                Remember: No more than one orgasm.
            ]]
        }
        local orgasmDenialRolls = {
            orgasmDenialRollNoUnlock,
            orgasmDenialRollNoOrgasm,
            orgasmDenialRollNoOrgasm,
            orgasmDenialRollRuinedOrgasm,
            orgasmDenialRollRuinedOrgasm,
            orgasmDenialRollFullOrgasm,
        }
        local cumEatingRolls = {
            'Cum may go anywhere',
            'Cum into your hand, lick it out from your hand, swallow',
            'Cum into your hand, let it drip into your mouth, swallow',
            'Cum into your mouth, swallow',
            'Cum into your mouth, taste for 5 minutes, swallow',
            'Cum into a condom, put the condom in your mouth, roll it around for 5 minutes, pull the condom out, swallow the cum',
        }

        if persistent.variantOrgasmDenial then
            renderRollDialog({
                id = 'rollOrgasmDenial',
                rollIdPrefix = 'variantOrgasmDenialRoll',
                text = 'Orgasm denial',
                subtext = [[
                    Since you have chosen the Orgasm Denial variant, let's see if you will get to have an orgasm today.
                    Press the <i>Roll task</i> button below.
                ]],
                rolls = util.map(orgasmDenialRolls, function(k, v) return k, v.text end),
                rollFinishMessages = util.map(orgasmDenialRolls, function(k, v) return k, v.rollFinishMessage end),
                enablePredicate = function() return true end,
            })
        else
            gui.renderText({
                text = [[
                    First and foremost, what you have been waiting for all this time; grab the key for your chastity
                    device and unlock yourself. Don't get too excited yet, keep reading!
                ]]
            })
        end

        if persistent.variantCumEating then
            renderRollDialog({
                id = 'rollCumEating',
                rollIdPrefix = 'variantCumEatingRoll',
                text = 'Cum eating',
                subtext = (function()
                    if (not persistent.variantOrgasmDenial)
                        or (persistent.requestUnlock.rollOrgasmDenialFinished
                            and orgasmDenialRolls[persistent.requestUnlock.rollOrgasmDenial].orgasm) then
                        return [[
                            Since you have chosen the Cum Eating variant, let's find out how you will get to finish masturbating.
                            Press the <i>Roll task</i> button below.
                        ]]
                    elseif persistent.variantOrgasmDenial
                            and persistent.requestUnlock.rollOrgasmDenialFinished
                            and not orgasmDenialRolls[persistent.requestUnlock.rollOrgasmDenial].orgasm then
                        return "Seems like you won't even get to roll for this variant, this time."
                    else
                        return 'Finish the Orgasm Denial roll above, first.'
                    end
                end)(),
                rolls = cumEatingRolls,
                enablePredicate = function()
                    return (not persistent.variantOrgasmDenial)
                        or (persistent.requestUnlock.rollOrgasmDenialFinished and orgasmDenialRolls[persistent.requestUnlock.rollOrgasmDenial].orgasm)
                end,
            })
        end

        if not persistent.variantOrgasmDenial then
            local enabled = (not persistent.variantCumEating) or persistent.requestUnlock.rollCumEatingFinished

            if enabled then
                gui.renderText({
                    text = [[
                        Feel free to masturbate! You can finish in one of the two following ways. Either choose a variant
                        beforehand, or you can also tap on it after you have finished. Keep in mind, that your choice will
                        influence the duration of your next chastity sentence. 💕
                    ]]
                })
            else
                gui.renderText({ subtext = 'Finish the Cum Eating roll above, first.' })
            end

            local function renderChoice(args)
                renderItem({
                    id = 'freeChoice'..tostring(args.index),
                    text = args.text,
                    subtext = 'Tap to choose this variant',
                    iconStart = '🔹',
                    iconEnd = (function()
                        if persistent.requestUnlock.chosenVariant == args.index
                        then return '✔️' else return '◻️' end
                    end)(),
                    opacity = (function()
                        if enabled and (persistent.requestUnlock.chosenVariant == args.index or not persistent.requestUnlock.chosenVariant)
                        then return 1.0 else return 0.5 end
                    end)(),
                    handler = function()
                        if not enabled then
                            return
                        elseif persistent.requestUnlock.chosenVariant == args.index then
                            persistent.requestUnlock.chosenVariant = nil
                            persistent.requestUnlock.chastitySentenceMultiplier = nil
                        else
                            persistent.requestUnlock.chosenVariant = args.index
                            persistent.requestUnlock.chastitySentenceMultiplier = args.chastitySentenceMultiplier
                        end

                        persistence.commit()
                        gui.render()
                    end
                })
            end

            renderChoice({
                index = 1,
                chastitySentenceMultiplier = 0.5,
                text = 'Have a ruined orgasm (stop masturbating 2 seconds before having an orgasm) with the advantage of the next chastity sentence being half as long; or',
            })
            renderChoice({
                index = 2,
                chastitySentenceMultiplier = 1.0,
                text = 'Have a full orgasm with the next chastity sentence being the full length',
            })
        end

        local returnEnabled = (function()
            if         persistent.variantCumEating and     persistent.variantOrgasmDenial then
                return not not ((persistent.requestUnlock.rollOrgasmDenialFinished
                                 and not orgasmDenialRolls[persistent.requestUnlock.rollOrgasmDenial].orgasm)
                                or persistent.requestUnlock.rollCumEatingFinished)
            elseif     persistent.variantCumEating and not persistent.variantOrgasmDenial then
                return not not persistent.requestUnlock.chosenVariant
            elseif not persistent.variantCumEating and     persistent.variantOrgasmDenial then
                return not not persistent.requestUnlock.rollOrgasmDenialFinished
            elseif not persistent.variantCumEating and not persistent.variantOrgasmDenial then
                return not not persistent.requestUnlock.chosenVariant
            end
        end)()

        gui.renderText({
            subtext = 'Once you have finished, lock yourself back up and put the key away, then click the button below.',
            opacity = (function() if returnEnabled then return 1.0 else return 0.5 end end)(),
        })
        gui.renderButton({
            text = '<big>🔐</big> I am locked',
            width = 'matchParent',
            enabled = returnEnabled,
            handler = function()
                persistent.score = persistent.score + 1
                persistent.chastitySentence = persistent.chastitySentence + persistent.difficulty
                persistent.daysRemaining = math.ceil(persistent.chastitySentence * (persistent.requestUnlock.chastitySentenceMultiplier or 1.0))

                if persistent.variantOrgasmDenial then
                    persistent.streakOrgasmDenial = (persistent.streakOrgasmDenial or 0) + 1
                end

                if persistent.variantCumEating then
                    persistent.streakCumEating = (persistent.streakCumEating or 0) + 1
                end

                persistent.requestUnlock = nil

                transitionState('main', nil, true)
            end,
        })

        --[[
        gui.renderButton({
            text = 'DEBUG CANCEL',
            handler = function()
                persistent.requestUnlock = nil
                transitionState('main', nil, true)
            end
        })
        ]]
    end,
}

-- @param `now` optional
local function rescheduleDailyTaskReset(now)
    time.scheduleNotificationAt({
        id = 'dailyTaskReset',
        instant = getFollowingDailyTaskResetInstant(now),
        data = {
            type = 'dailyTaskReset',
        },
    })
end

local function onDailyTaskReset(notification)
    persistent.daysRemaining = persistent.daysRemaining + persistent.dailySentenceDelta
    rescheduleDailyTaskReset()
    persistence.commit()
end

local function onNotifyTaskCompletion(notification)
    print('Completion notification: '..notification.data.task.id)
    persistent.daysRemaining = persistent.daysRemaining - notification.data.task.subtractedDays
    scheduleNotificationRender()
    persistence.commit()
end

local function onNotifyTaskCooldown(notification)
    print('Cooldown notification: '..notification.data.task.id)
    scheduleNotificationRender()
end

local function onNotifyRollAnimationFinish(notification)
    local currentRoll = notification.data.rollToUpdate
    persistent.requestUnlock[notification.id..'Finished'] = true

    persistence.commit()
    gui.render()
end

local function onNotifyRollAnimation(notification)
    if not persistent.requestUnlock or not persistent.requestUnlock[notification.id] then
        return
    end

    local currentRoll = notification.data.rollToUpdate
    local previousRoll = ((currentRoll - 2) % 6) + 1
    local nextRoll = ((currentRoll - 0) % 6) + 1

    gui.updateElement({
        id = notification.data.rollIdPrefix..previousRoll..'IconStart',
        data = { text = '<big><big>'..numberSymbols[previousRoll]..'</big></big>' },
    })
    gui.updateElement({
        id = notification.data.rollIdPrefix..currentRoll..'IconStart',
        data = { text = '<big><big>'..arrowSymbol..'</big></big>' },
    })

    if notification.data.remainingAnimationTasks > 0 then
        time.scheduleNotificationAfter({
            id = notification.id,
            duration = { milliseconds = getRollDelayMillis(notification.data.remainingAnimationTasks) },
            data = {
                type = 'rollAnimation',
                rollIdPrefix = notification.data.rollIdPrefix,
                rollToUpdate = nextRoll,
                remainingAnimationTasks = notification.data.remainingAnimationTasks - 1,
            },
        })
    else
        onNotifyRollAnimationFinish(notification)
    end
end

function onNotify(notification)
    if     notification.data.type == 'dailyTaskReset' then onDailyTaskReset(notification)
    elseif notification.data.type == 'taskCompletion' then onNotifyTaskCompletion(notification)
    elseif notification.data.type == 'taskCooldown'   then onNotifyTaskCooldown(notification)
    elseif notification.data.type == 'rollAnimation'  then onNotifyRollAnimation(notification)
    elseif notification.data.type == 'render'         then gui.render()
    end
end

function onRender()
    states[persistent.state]()
end

gui.render()
