import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Trip-planner popup. Field wiring follows the network plugin's
// passphrase-prompt pattern: text bound to a backing property, an explicit
// `editing` flag gating PanelKeyCatcher, and Qt.callLater(forceActiveFocus).
//
// The window itself is a hand-built PanelWindow rather than qs.Ui's shared
// KeyboardPanel. KeyboardPanel primes Wayland keyboard focus as Exclusive
// for ~75ms on open, then downgrades to OnDemand — and on at least one
// tested compositor that downgrade can leave the surface with no keyboard
// focus at all (mouse clicks still land since pointer routing doesn't need
// keyboard focus, but every keystroke is lost). akshar.radio-atlas sidesteps
// this by tying WlrLayershell.keyboardFocus directly to a HoverHandler
// instead of a one-shot timer, which is proven reliable here — this file
// follows that same pattern.
Panel {
  id: root
  moduleName: "io.github.ozdadirri.sydney-train-planer"
  ipcTarget: "io.github.ozdadirri.sydney-train-planer"
  manageIpc: false

  // Injected by BarWidget.qml.
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property bool openedFromHotkey: false

  // Emitted when a journey is tapped; BarWidget persists it as the default.
  signal pinned(var origin, var destination)

  // ---- config (own read of the shared state file) ------------------------
  readonly property string apiKey: String(fileCfg.apiKey || "")
  readonly property int resultCount: 4

  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/syd-train.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: Qt.callLater(root.seedFromConfig)
    JsonAdapter {
      id: fileCfg
      property string apiKey: ""
      property string originId: ""
      property string originName: ""
      property string destinationId: ""
      property string destinationName: ""
    }
  }

  // ---- panel lifecycle --------------------------------------------------
  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    seedFromConfig()
  }
  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    seedFromConfig()
    Qt.callLater(function() { if (root.opened) setCenterHoverRevealSuppressed(true) })
  }
  function close() {
    editing = false
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }
  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- planner state --------------------------------------------------
  // Field contents live in these backing properties. Code writes here; the
  // change handlers push the value into the TextField imperatively (a plain
  // `text:` binding would be silently broken the first time the user types).
  property string originText: ""
  property string destText: ""
  onOriginTextChanged: if (originField.text !== originText) originField.text = originText
  onDestTextChanged: if (destField.text !== destText) destField.text = destText

  property var originStop: ({ id: "", name: "" })
  property var destStop: ({ id: "", name: "" })
  readonly property bool ready: originStop.id !== "" && destStop.id !== "" && apiKey !== ""

  property var trips: []
  property string status: ""
  property bool locating: false
  property date lastUpdated: new Date(0)
  property date now: new Date()
  // Index into `trips` of the journey whose leg-by-leg detail (interchange
  // stops, platforms, times) is expanded; -1 when none is. Reset whenever
  // a fresh set of journeys comes in so a stale expansion can't point at
  // the wrong trip.
  property int expandedTripIndex: -1
  // Which trip's pin button most recently fired, so its icon can flash a
  // checkmark for a moment — pinning a trip that's already saved writes
  // identical JSON, which is otherwise a silent no-op.
  property int justPinnedIndex: -1

  property string activeField: ""     // "origin" | "dest" | ""
  property var suggestions: []
  property string _pendingQuery: ""
  property string _pendingField: ""

  // True while a text field is being edited. PanelKeyCatcher grabs keys with
  // Keys.BeforeItem priority (vim-style nav), so it MUST be `blocked` while
  // typing or every keystroke is swallowed as a navigation command. This is
  // an explicit flag, not `field.activeFocus`, so it flips the instant the
  // field is tapped rather than one focus-event later.
  property bool editing: false
  function stopEditing() {
    editing = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // When the panel opens with no trip yet, focus the origin field straight
  // away so the user can just start typing (mirrors the network plugin
  // focusing its passphrase field on show).
  onOpenedChanged: {
    editing = false
    if (opened && originStop.id === "") {
      Qt.callLater(function() {
        if (!root.opened) return
        root.editing = true
        root.activeField = "origin"
        originField.forceActiveFocus()
      })
    }
  }

  function seedFromConfig() {
    if (originStop.id === "" && fileCfg.originId !== "") {
      originStop = { id: fileCfg.originId, name: fileCfg.originName }
      originText = fileCfg.originName
    }
    if (destStop.id === "" && fileCfg.destinationId !== "") {
      destStop = { id: fileCfg.destinationId, name: fileCfg.destinationName }
      destText = fileCfg.destinationName
    }
    if (ready) planTrip()
  }

  function fmtTime(iso) {
    if (!iso) return "--:--"
    var d = new Date(iso)
    return isNaN(d.getTime()) ? "--:--" : Qt.formatTime(d, "h:mm AP")
  }
  function countdown(iso) {
    if (!iso) return ""
    var m = Math.round((new Date(iso).getTime() - root.now.getTime()) / 60000)
    if (m < 0) return "departed"
    if (m === 0) return "now"
    if (m < 60) return m + " min"
    return Math.floor(m / 60) + "h " + (m % 60) + "m"
  }

  function swap() {
    var o = originStop, d = destStop
    originStop = { id: d.id, name: d.name }
    destStop = { id: o.id, name: o.name }
    originText = originStop.name
    destText = destStop.name
    suggestions = []; activeField = ""; editing = false
    planTrip()
  }

  function chooseSuggestion(item) {
    var picked = { id: item.id, name: item.disassembledName || item.name }
    if (activeField === "origin") {
      originStop = picked
      originText = picked.name
    } else if (activeField === "dest") {
      destStop = picked
      destText = picked.name
    }
    suggestions = []; activeField = ""
    stopEditing()
    planTrip()
  }

  function queueSearch(q, field) {
    _pendingQuery = q; _pendingField = field
    debounce.restart()
  }
  function searchStops(query, field) {
    activeField = field
    if (String(query || "").trim().length < 3) { suggestions = []; return }
    stopProc.pending = query
    if (!stopProc.running) stopProc.fire()
  }

  function planTrip() {
    if (!ready) { trips = []; return }
    if (tripProc.running) return
    var d = new Date()
    status = "Loading…"
    tripProc.command = Model.curlArgs(
      Model.tripUrl(originStop.id, destStop.id,
        Qt.formatDate(d, "yyyyMMdd"), Qt.formatTime(d, "HHmm")),
      apiKey, 10)
    tripProc.running = true
  }

  function useCurrentLocation() {
    if (locating) return
    locating = true
    status = "Detecting your location…"
    geoProc.running = true
  }

  // ---- processes -----------------------------------------------------------
  Process {
    id: stopProc
    property string pending: ""
    property string active: ""
    function fire() {
      active = pending
      command = Model.curlArgs(Model.stopFinderUrl(active), root.apiKey, 6)
      running = true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.suggestions = Model.parseStopFinder(text)
        if (stopProc.pending !== stopProc.active) Qt.callLater(stopProc.fire)
      }
    }
  }

  Process {
    id: tripProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseTrip(text)
        root.trips = parsed
        root.expandedTripIndex = -1
        root.justPinnedIndex = -1
        root.status = parsed.length ? "" : "No journeys found"
        if (parsed.length) root.lastUpdated = new Date()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var e = String(text || "").trim()
        if (e && !root.trips.length) root.status = "TfNSW request failed"
      }
    }
  }

  Process {
    id: geoProc
    command: ["curl", "-fsS", "--max-time", "6", "https://ipapi.co/json/"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locating = false
        try {
          var j = JSON.parse(String(text || "{}"))
          if (j.latitude && j.longitude) {
            root.originStop = {
              id: Model.coordId(j.latitude, j.longitude),
              name: "Current location" + (j.city ? " (" + j.city + ")" : "")
            }
            root.originText = root.originStop.name
            root.status = ""
            root.planTrip()
            return
          }
        } catch (e) {}
        root.status = "Could not detect location"
      }
    }
  }

  Timer {
    id: debounce
    interval: 280
    onTriggered: root.searchStops(root._pendingQuery, root._pendingField)
  }

  Timer {
    id: justPinnedTimer
    interval: 1200
    onTriggered: root.justPinnedIndex = -1
  }

  Timer {
    interval: 15000
    repeat: true
    running: root.opened
    onTriggered: root.now = new Date()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
  }

  PanelWindow {
    id: panel
    screen: root.anchorItem && root.anchorItem.QsWindow && root.anchorItem.QsWindow.window
      ? root.anchorItem.QsWindow.window.screen : null
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "io.github.ozdadirri.sydney-train-planer"
    WlrLayershell.layer: WlrLayer.Overlay
    // Tied straight to the pointer, not a one-shot prime timer — see the
    // import-block comment above for why.
    WlrLayershell.keyboardFocus: root.opened && cardHover.hovered
      ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    readonly property int barSize: root.bar ? root.bar.barSize : 0
    readonly property string barPos: root.bar ? root.bar.position : "top"
    readonly property bool barHorizontal: barPos === "top" || barPos === "bottom"
    readonly property int cardWidth: Math.min(Style.space(480), panel.width - Style.gapsOut * 2)
    readonly property int cardHeight: Math.min(
      content.implicitHeight + Style.spacing.popupPadding * 2 + Style.space(4),
      panel.height - barSize - Style.gapsOut * 2)

    // Full-screen mask minus the bar strip itself: a click anywhere else on
    // screen needs to reach this window so `dismissArea` below can close
    // it (matching KeyboardPanel's outside-click-to-dismiss), while the bar
    // strip is carved out so its own widgets keep receiving clicks
    // directly, unaffected by this window sitting above it.
    mask: Region {
      width: panel.width
      height: panel.height
      regions: [
        Region {
          intersection: Intersection.Subtract
          x: panel.barPos === "right" ? panel.width - panel.barSize : 0
          y: panel.barPos === "bottom" ? panel.height - panel.barSize : 0
          width: panel.barHorizontal ? panel.width : panel.barSize
          height: panel.barHorizontal ? panel.barSize : panel.height
        }
      ]
    }

    // Catches every click on screen while open; the card has its own
    // MouseArea (below) so clicks on it don't bubble up here.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      x: Math.round(panel.width / 2 - width / 2)
      y: (root.bar && root.bar.position === "bottom")
        ? panel.height - panel.barSize - height - Style.gapsOut
        : panel.barSize + Style.gapsOut
      width: panel.cardWidth
      height: panel.cardHeight
      color: Color.popups.background
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.popupPadding
      radius: Style.cornerRadius

      HoverHandler {
        id: cardHover
        onHoveredChanged: if (hovered) keyCatcher.forceActiveFocus()
      }

      // Swallows clicks that land on the card but miss every interactive
      // descendant (a journey row's padding, blank space below the list),
      // so they don't fall through to the full-screen dismissArea behind
      // and close the panel. Declared before the interactive content below
      // so those items — being later siblings, on top in the stacking
      // order — still get first claim on any click within their own
      // bounds.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
      }

      // BorderSurface's `padding` only shows up via these inset properties —
      // it does nothing to a child anchored straight to the card itself, so
      // without this the content sat flush against the border.
      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: root.editing
        onCloseRequested: root.close()
        onTabRequested: function(direction) { root.switchPanel(direction) }

        Column {
          id: content
          width: parent.width
          spacing: Style.space(10)

        // Header
        Item {
          width: parent.width
          height: headerRefresh.implicitHeight
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "SYDNEY TRAINS"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }
          Button {
            id: headerRefresh
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            tooltipText: "Refresh"
            foreground: root.bar.foreground
            verticalPadding: 2
            horizontalPadding: 4
            onClicked: root.planTrip()
          }
        }

        // From
        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            width: Style.space(44)
            text: "From"
            anchors.verticalCenter: parent.verticalCenter
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
          TextField {
            id: originField
            width: parent.width - Style.space(44) - Style.space(8) - locBtn.width - Style.space(8)
            placeholderText: "Origin stop"
            foreground: root.bar.foreground
            onTextChanged: {
              if (text === root.originText) return
              root.originText = text
              root.originStop = { id: "", name: text }
              root.queueSearch(text, "origin")
            }
            onActiveFocusChanged: if (activeFocus) { root.editing = true; root.activeField = "origin" }
            Keys.onEscapePressed: { root.originText = ""; root.stopEditing() }
            // A bare click doesn't reliably hand this field Qt's active
            // focus inside the KeyboardPanel/PanelKeyCatcher stack (see the
            // weather and network plugins, which always drive focus via an
            // explicit forceActiveFocus() call rather than relying on the
            // TextField's own click handling). Disabled once already
            // focused so a click mid-text still repositions the cursor
            // normally instead of re-grabbing focus every time.
            MouseArea {
              anchors.fill: parent
              enabled: !originField.activeFocus
              cursorShape: Qt.IBeamCursor
              onPressed: Qt.callLater(function() { originField.forceActiveFocus() })
            }
          }
          Button {
            id: locBtn
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.locating ? "󰦖" : "󰆤"
            iconSpinning: root.locating
            tooltipText: "Use current location"
            foreground: root.bar.foreground
            bordered: true
            onClicked: root.useCurrentLocation()
          }
        }

        // Swap
        Button {
          anchors.horizontalCenter: parent.horizontalCenter
          iconText: "󰓡"
          tooltipText: "Swap origin and destination"
          foreground: root.bar.foreground
          onClicked: root.swap()
        }

        // To
        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            width: Style.space(44)
            text: "To"
            anchors.verticalCenter: parent.verticalCenter
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
          TextField {
            id: destField
            width: parent.width - Style.space(44) - Style.space(8)
            placeholderText: "Destination stop"
            foreground: root.bar.foreground
            onTextChanged: {
              if (text === root.destText) return
              root.destText = text
              root.destStop = { id: "", name: text }
              root.queueSearch(text, "dest")
            }
            onActiveFocusChanged: if (activeFocus) { root.editing = true; root.activeField = "dest" }
            Keys.onEscapePressed: { root.destText = ""; root.stopEditing() }
            MouseArea {
              anchors.fill: parent
              enabled: !destField.activeFocus
              cursorShape: Qt.IBeamCursor
              onPressed: Qt.callLater(function() { destField.forceActiveFocus() })
            }
          }
        }

        // Suggestions
        Column {
          width: parent.width
          spacing: 0
          visible: root.suggestions.length > 0
          Repeater {
            model: root.suggestions
            Rectangle {
              required property var modelData
              required property int index
              width: parent.width
              height: sRow.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: sArea.containsMouse
                ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
              Row {
                id: sRow
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)
                Text {
                  text: modelData.disassembledName || modelData.name
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  text: modelData.type === "stop" ? "" : modelData.type
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              MouseArea {
                id: sArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.chooseSuggestion(modelData)
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.bar.foreground
          opacity: 0.12
          visible: root.trips.length > 0 || root.status !== ""
        }

        Text {
          visible: root.status !== "" && root.trips.length === 0
          text: root.status
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        // Journeys. Tapping a row expands/collapses its leg-by-leg detail
        // (interchange stops, platforms, times); pinning the trip to the
        // bar has its own explicit button so it doesn't fight that tap.
        Repeater {
          model: root.trips.slice(0, root.resultCount)
          Column {
            required property var modelData
            required property int index
            width: parent.width

            Rectangle {
              width: parent.width
              height: jCol.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: jArea.containsMouse || root.expandedTripIndex === index
                ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

              Column {
                id: jCol
                anchors.left: parent.left
                anchors.right: pinBtn.left
                anchors.rightMargin: Style.space(6)
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Row {
                  width: parent.width
                  spacing: Style.space(10)
                  Text {
                    width: Style.space(66)
                    text: root.countdown(modelData.depEstimated)
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    text: root.fmtTime(modelData.depEstimated) + " → " + root.fmtTime(modelData.arrEstimated)
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    text: (modelData.durationMin != null ? "· " + modelData.durationMin + " min" : "")
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  Text {
                    width: Style.space(66)
                    text: (modelData.lines && modelData.lines.length) ? modelData.lines.join(" › ") : modelData.modes.join(", ")
                    color: Color.accent
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    visible: modelData.platform !== ""
                    text: "Plat " + modelData.platform
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    visible: modelData.changes > 0
                    text: modelData.changes + " chg"
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    visible: modelData.delayMin > 0
                    text: "+" + modelData.delayMin + " min late"
                    color: Color.urgent
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }

              MouseArea {
                id: jArea
                anchors.fill: parent
                anchors.rightMargin: pinBtn.width + Style.space(6)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.expandedTripIndex = (root.expandedTripIndex === index ? -1 : index)
              }

              Button {
                id: pinBtn
                // Plain x/y instead of anchors.right: this Rectangle's other
                // two children each have a binding that reaches pinBtn
                // (jCol.anchors.right: pinBtn.left, jArea's rightMargin:
                // pinBtn.width + ...); with anchors.right used here too,
                // pinBtn's own x stayed stuck at 0 (logged at runtime)
                // instead of resolving against parent.width, which hid the
                // button under jCol/jArea entirely. Plain bindings resolve
                // reliably where the anchor did not.
                x: parent.width - width - Style.space(4)
                y: (parent.height - height) / 2
                // Briefly swap to a checkmark so a re-pin of the already-
                // saved trip still gives feedback — writing identical JSON
                // is a silent no-op otherwise.
                iconText: root.justPinnedIndex === index ? "󰄬" : "󰐃"
                tooltipText: "Pin this trip to the bar"
                foreground: root.bar.foreground
                verticalPadding: 2
                horizontalPadding: 4
                onClicked: {
                  root.editing = false
                  root.pinned(root.originStop, root.destStop)
                  root.justPinnedIndex = index
                  justPinnedTimer.restart()
                }
              }
            }

            // Leg-by-leg detail: interchange stops, platforms, and times.
            Column {
              width: parent.width
              visible: root.expandedTripIndex === index
              leftPadding: Style.space(6)
              rightPadding: Style.space(6)
              topPadding: Style.space(4)
              bottomPadding: Style.space(6)
              spacing: Style.space(6)

              Repeater {
                model: modelData.legs || []
                Column {
                  required property var modelData
                  required property int index
                  width: parent.width - Style.space(12)
                  spacing: Style.space(1)

                  Row {
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      text: modelData.isTransit ? modelData.line : "Walk"
                      color: modelData.isTransit ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                    Text {
                      visible: modelData.isTransit
                      text: "(" + modelData.mode + ")"
                      color: Qt.darker(root.bar.foreground, 1.5)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: root.fmtTime(modelData.depEstimated) + "  " + modelData.originName
                      + (modelData.originPlatform !== "" ? " · Plat " + modelData.originPlatform : "")
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: root.fmtTime(modelData.arrEstimated) + "  " + modelData.destName
                      + (modelData.destPlatform !== "" ? " · Plat " + modelData.destPlatform : "")
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    visible: modelData.waitMin !== null
                    text: "Change · " + modelData.waitMin + " min wait"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.italic: true
                  }
                }
              }
            }
          }
        }

        Text {
          visible: root.lastUpdated.getTime() > 0
          width: parent.width
          text: "Updated " + Qt.formatTime(root.lastUpdated, "h:mm:ss AP") + " · tap a journey to pin it to the bar"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
        }
      }
      }
    }
  }
}
