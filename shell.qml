import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "."
import "config.js" as Config
import "search.js" as Search

ShellRoot {
  id: root

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string cfgHome: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string configPath: Quickshell.env("ROSECLIP_CONFIG") || (cfgHome + "/roseclip/config.toml")
  readonly property string cacheDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/roseclip"
  readonly property string stateDir: stateHome + "/roseclip"
  readonly property string wallCachePath: stateDir + "/wallpaper.json"

  property var loaded: Config.load("")
  property bool hasGoodConfig: false

  readonly property var conf: loaded.conf
  readonly property var warnings: loaded.warnings

  
  readonly property bool md: conf.design === "md3e"
  readonly property bool springy: md && conf.md3.motion !== "standard"
  readonly property var  emphasized: [0.2, 0, 0, 1, 1, 1]

  Md3 {
    id: md3
    cfg: root.conf.md3
    active: root.md
    awake: root.shown
    onSeedAccepted: (key, seed) => wallFile.setText(JSON.stringify({ key: key, seed: seed }))
  }

  
  readonly property var mdPal: {
    var g = md3.roles;
    var p = {
      bg: g.surfaceContainer, surface: g.surfaceContainerHigh, border: g.outlineVariant,
      fg: g.onSurface, muted: g.onSurfaceVariant, accent: g.primary,
      selected_from: g.secondaryContainer, selected_to: g.secondaryContainer,
      selected_fg: g.onSecondaryContainer, hover: g.surfaceContainerHighest, urgent: g.error
    };
    var uc = conf.colors;
    for (var k in uc) if (uc[k] !== "") p[k] = uc[k];
    return p;
  }
  readonly property var pal: md ? mdPal : loaded.pal

  function layered(base, over, a) {
    var c = Qt.color(over);
    return Qt.tint(Qt.color(base), Qt.rgba(c.r, c.g, c.b, a));
  }

  function applyConfig(text) {
    var r = Config.load(text);

    if (r.fatal && hasGoodConfig) {
      r = {
        conf: loaded.conf,
        pal: loaded.pal,
        warnings: r.warnings,
        fatal: true
      };
    } else if (!r.fatal) {
      hasGoodConfig = true;
    }

    loaded = r;
  }

  FileView {
    id: cfgFile
    path: root.configPath
    blockLoading: true
    watchChanges: true
    printErrors: false

    onFileChanged: reload()
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.applyConfig("")
  }

  
  FileView {
    id: wallFile
    path: root.wallCachePath
    blockLoading: true
    printErrors: false
  }

  Process {
    command: ["mkdir", "-p", root.stateDir]
    running: true
  }

  Process {
    running: root.conf.behavior.mode === "daemon"
      && root.conf.behavior.watch_clipboard
    command: ["wl-paste", "--type", "text", "--watch", "cliphist", "store"]
  }

  Process {
    running: root.conf.behavior.mode === "daemon"
      && root.conf.behavior.watch_clipboard
    command: ["wl-paste", "--type", "image", "--watch", "cliphist", "store"]
  }

  property bool shown: false
  property string query: ""
  property int cur: 0

  
  property real t: shown ? 1 : 0
  Behavior on t {
    enabled: root.conf.animation.enabled
    NumberAnimation {
      duration: root.shown ? (root.springy ? 460 : 260) : 180
      easing.type: root.shown
        ? (root.springy ? Easing.OutBack : Easing.OutCubic)
        : Easing.InCubic
      easing.overshoot: 1.4
    }
  }

  
  property int  openGen: 0
  property bool staggerOn: false
  Timer {
    id: staggerTimer
    interval: 750
    onTriggered: root.staggerOn = false
  }

  property var records: []

  property var results: Search.run(
    records,
    query,
    conf.behavior.max_results
  )

  onResultsChanged: cur = 0

  Process {
    id: listProc

    command: ["sh", "-c",
      'd="$1"; mkdir -p "$d"; find "$d" -name "*.img" -mtime +1 -delete\n' +
      'cliphist -preview-width "$3" list | head -n "$2" > "$d/list.txt"\n' +
      'grep -a "\\[\\[ binary data" "$d/list.txt" | cut -f1 | while read -r id; do [ -f "$d/$id.img" ] || cliphist decode "$id" > "$d/$id.img"; done\n' +
      'cat "$d/list.txt"',
      "sh",
      root.cacheDir,
      String(root.conf.behavior.max_results),
      String(root.conf.behavior.preview_chars)]

    stdout: StdioCollector {
      onStreamFinished: root.records = Search.buildRecords(text)
    }
  }

  readonly property real pitch: conf.list.row_height + conf.list.row_gap

  readonly property real fullListH:
  conf.list.visible_rows * pitch - conf.list.row_gap

  readonly property real listHeight: {
    var content = results.length * pitch - conf.list.row_gap;

    return conf.list.shrink_to_fit
      ? Math.max(0, Math.min(fullListH, content))
      : fullListH;
  }

  readonly property real fullCardH:
  conf.window.padding * 2
  + conf.search.height
  + conf.window.gap
  + fullListH

  readonly property string fontFamily:
  conf.font.family !== ""
    ? conf.font.family
    : Qt.application.font.family

  readonly property string iconFont: md ? conf.md3.icon_font : fontFamily

  function open(reload) {
    if (reload) cfgFile.reload();

    input.text = "";
    query = "";
    cur = 0;
    staggerOn = true;
    staggerTimer.restart();
    openGen++;
    shown = true;
    listProc.running = true;

    Qt.callLater(function() {
      input.forceActiveFocus();
    });
  }

  function close() {
    shown = false;

    if (conf.behavior.mode !== "daemon") {
      quitTimer.start();
    }
  }

  Timer {
    id: quitTimer
    interval: root.conf.animation.enabled ? 280 : 0
    onTriggered: Qt.quit()
  }

  function pick(rec) {
    if (!rec) return;

    var b = conf.behavior;

    Quickshell.execDetached(["sh", "-c",
      'cliphist decode "$1" | wl-copy; if [ "$2" = 1 ]; then sleep "$3"; eval "$4"; fi',
      "sh",
      rec.id,
      b.auto_paste ? "1" : "0",
      String(b.paste_delay_ms / 1000),
      b.paste_command]);

    close();
  }

  function del(rec) {
    if (!rec) return;

    Quickshell.execDetached(["sh", "-c",
      'printf "%s\\n" "$1" | cliphist delete; rm -f "$2/$3.img"',
      "sh", rec.raw, cacheDir, rec.id]);

    var keep = cur;

    records = records.filter(function(r) {
      return r.id !== rec.id;
    });

    cur = Math.max(0, Math.min(keep, results.length - 1));
  }

  function wipe() {
    Quickshell.execDetached(["sh", "-c",
      'cliphist wipe; rm -f "$1"/*.img', "sh", cacheDir]);

    records = [];
  }

  function move(d) {
    var n = results.length;

    if (n === 0) return;

    var t = cur + d;

    if (conf.behavior.wrap && Math.abs(d) === 1) {
      t = (t + n) % n;
    } else {
      t = Math.max(0, Math.min(n - 1, t));
    }

    cur = t;
  }

  function handleKey(ev) {
    var ctrl = (ev.modifiers & Qt.ControlModifier) !== 0;
    var shift = (ev.modifiers & Qt.ShiftModifier) !== 0;
    var rows = Math.max(1, Math.floor(conf.list.visible_rows));

    if (ev.key === Qt.Key_Escape) {
      close();
    } else if (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) {
      pick(results[cur]);
    } else if (
      ev.key === Qt.Key_Down
        || ev.key === Qt.Key_Tab
        || (ctrl && (ev.key === Qt.Key_J || ev.key === Qt.Key_N))
    ) {
      move(1);
    } else if (
      ev.key === Qt.Key_Up
        || ev.key === Qt.Key_Backtab
        || (ctrl && (ev.key === Qt.Key_K || ev.key === Qt.Key_P))
    ) {
      move(-1);
    } else if (ev.key === Qt.Key_PageDown) {
      move(rows);
    } else if (ev.key === Qt.Key_PageUp) {
      move(-rows);
    } else if (ctrl && ev.key === Qt.Key_U) {
      input.text = "";
    } else if (ctrl && shift && ev.key === Qt.Key_D) {
      wipe();
    } else if (
      (ctrl && ev.key === Qt.Key_D)
        || (ev.key === Qt.Key_Delete && input.text === "")
    ) {
      del(results[cur]);
    } else {
      return;
    }

    ev.accepted = true;
  }

  function pickScreen() {
    var s = Quickshell.screens;

    for (var i = 0; i < s.length; i++) {
      if (s[i].name === conf.window.monitor) return s[i];
    }

    return s[0];
  }

  IpcHandler {
    target: "roseclip"

    function toggle(): void {
      if (root.shown) root.close();
      else root.open(true);
    }

    function open(): void {
      root.open(true);
    }

    function close(): void {
      root.close();
    }
  }

  Component.onCompleted: {
    try {
      applyConfig(cfgFile.text());
    } catch (e) {
      applyConfig("");
    }

    
    try {
      var wc = JSON.parse(wallFile.text());
      if (wc && wc.seed) {
        md3.wallKey = wc.key || "";
        md3.wallSeed = wc.seed;
      }
    } catch (e3) {
    }
    md3.ready = true;

    if (conf.behavior.mode !== "daemon") open(false);
  }

  PanelWindow {
    id: win

    
    visible: root.shown || root.t > 0.002
    color: "transparent"

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "roseclip"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Binding {
      target: win
      property: "screen"
      value: root.pickScreen()
      when: root.conf.window.monitor !== ""
    }

    Rectangle {
      anchors.fill: parent
      color: "black"
      opacity: root.conf.window.dim * Math.min(1, root.t)
      visible: opacity > 0
    }

    MouseArea {
      anchors.fill: parent

      onClicked: {
        if (root.conf.behavior.close_on_click_outside) {
          root.close();
        }
      }
    }

    Rectangle {
      id: card

      width: Math.min(root.conf.window.width, win.width - 40)
      height: col.height + root.conf.window.padding * 2
      x: Math.round((win.width - width) / 2)
      y: Math.round(
        (win.height - root.fullCardH) / 2
        + root.conf.window.offset_y
      )

      radius: root.conf.window.radius
      color: Qt.alpha(root.pal.bg, root.conf.window.opacity)
      Behavior on color { enabled: root.md; ColorAnimation { duration: 400 } }

      border.width: root.conf.window.border_width
      border.color: root.pal.border

      
      opacity: Math.min(1, root.t * 1.6)
      scale: 0.86 + 0.14 * root.t
      transform: Translate { y: (1 - root.t) * 36 }

      Behavior on width {
        enabled: root.conf.animation.enabled
          && root.conf.animation.resize_ms > 0

        NumberAnimation {
          duration: root.conf.animation.resize_ms
          easing.type: Easing.OutCubic
        }
      }

      MouseArea {
        anchors.fill: parent
      }

      Column {
        id: col

        x: root.conf.window.padding
        y: root.conf.window.padding

        width: card.width - root.conf.window.padding * 2
        spacing: root.conf.window.gap

        
        Item {
          width: parent.width
          height: root.conf.search.height

          
          Rectangle {
            id: ring
            anchors.fill: parent
            radius: searchBar.radius
            color: "transparent"
            border.width: 2
            border.color: root.pal.accent
            opacity: 0
            visible: root.md && opacity > 0.01

            SequentialAnimation {
              id: ringAnim
              ScriptAction { script: { ring.opacity = 0.9; ring.scale = 1.0; } }
              PauseAnimation { duration: 140 }
              ParallelAnimation {
                NumberAnimation { target: ring; property: "opacity"; to: 0; duration: 520
                                  easing.type: Easing.OutCubic }
                NumberAnimation { target: ring; property: "scale"; to: 1.08; duration: 520
                                  easing.type: Easing.OutCubic }
              }
            }
            Connections {
              target: root
              function onOpenGenChanged() {
                if (root.md && root.conf.animation.enabled) ringAnim.restart();
              }
            }
          }

          Rectangle {
            id: searchBar
            anchors.fill: parent

            radius: root.md ? height / 2 : root.conf.search.radius

            color: root.pal.surface
            Behavior on color { enabled: root.md; ColorAnimation { duration: 400 } }

            border.width: root.conf.search.border_width
            border.color: root.pal.accent

            Text {
              id: sIcon

              anchors.left: parent.left
              anchors.leftMargin: root.conf.search.padding_x
              anchors.verticalCenter: parent.verticalCenter

              text: root.conf.search.icon
              color: root.md ? root.pal.muted : root.pal.selected_from
              Behavior on color { enabled: root.md; ColorAnimation { duration: 300 } }

              font.family: root.iconFont
              font.pixelSize: root.conf.search.icon_size

              
              Connections {
                target: root
                function onOpenGenChanged() {
                  if (root.md && root.conf.animation.enabled) iconPop.restart();
                }
              }
              SequentialAnimation {
                id: iconPop
                NumberAnimation { target: sIcon; property: "scale"; to: 0.5; duration: 80
                                  easing.type: Easing.InCubic }
                NumberAnimation { target: sIcon; property: "scale"; to: 1; duration: 380
                                  easing.type: Easing.OutBack; easing.overshoot: 3 }
              }
            }

            TextInput {
              id: input

              anchors.left: sIcon.right
              anchors.leftMargin: 10
              anchors.right: parent.right
              anchors.rightMargin: root.conf.search.padding_x + (root.md ? 36 : 0)
              anchors.verticalCenter: parent.verticalCenter

              clip: true
              focus: true

              color: root.pal.fg
              selectionColor: root.md ? root.pal.accent : root.pal.selected_from
              selectedTextColor: root.md ? root.pal.bg : root.pal.selected_fg

              font.family: root.fontFamily
              font.pixelSize: root.conf.font.size
              font.weight: root.conf.font.weight_n
              font.italic: root.conf.font.italic
              font.letterSpacing: root.conf.font.letter_spacing

              onTextChanged: {
                root.query = text;
                if (text !== "") root.staggerOn = false;
              }

              Keys.onPressed: function(event) {
                root.handleKey(event);
              }

              Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter

                text: root.conf.search.placeholder
                color: root.pal.muted
                font: input.font

                
                opacity: input.text === "" ? 1 : 0
                x: input.text === "" ? 0 : 10
                visible: opacity > 0.01
                Behavior on opacity { enabled: root.md; NumberAnimation { duration: 150 } }
                Behavior on x {
                  enabled: root.md
                  NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
                }
              }
            }

            
            Rectangle {
              id: clearBtn

              visible: root.md && opacity > 0.01
              anchors.right: parent.right
              anchors.rightMargin: Math.max(4, root.conf.search.padding_x - 6)
              anchors.verticalCenter: parent.verticalCenter

              width: 32
              height: 32
              radius: 16

              color: root.layered(root.pal.surface, root.pal.fg,
                                  clearTap.pressed ? 0.16 : (clearHover.hovered ? 0.1 : 0))
              Behavior on color { ColorAnimation { duration: 120 } }

              opacity: input.text !== "" ? 1 : 0
              scale: clearTap.pressed ? 0.85 : (input.text !== "" ? 1 : 0.4)
              Behavior on opacity { NumberAnimation { duration: 140 } }
              Behavior on scale {
                NumberAnimation {
                  duration: root.springy ? 360 : 200
                  easing.type: root.springy ? Easing.OutBack : Easing.OutCubic
                  easing.overshoot: 2.4
                }
              }

              Text {
                anchors.centerIn: parent
                text: ""
                color: root.pal.muted
                font.family: root.iconFont
                font.pixelSize: 14
              }

              HoverHandler { id: clearHover }
              TapHandler {
                id: clearTap
                onTapped: {
                  input.text = "";
                  input.forceActiveFocus();
                }
              }
            }
          }
        }

        
        Item {
          visible: root.results.length > 0
          width: parent.width
          height: root.listHeight

          Behavior on height {
            enabled: root.conf.animation.enabled
              && root.conf.animation.resize_ms > 0

            NumberAnimation {
              duration: root.md ? (root.springy ? 420 : 280) : root.conf.animation.resize_ms
              easing.type: root.md && root.springy ? Easing.OutBack : Easing.OutCubic
              easing.overshoot: 1.1
            }
          }

          
          Component {
            id: hlComp

            Rectangle {
              readonly property var it: list.currentItem
              readonly property bool down: it !== null && it.pressed

              visible: it !== null
              width: list.width
              y: it ? it.y : 0
              height: it ? it.height : root.conf.list.row_height

              color: root.pal.selected_from
              Behavior on color { ColorAnimation { duration: 400 } }

              
              radius: down ? Math.min(12, height / 2)
                           : Math.min(root.conf.list.row_radius, height / 2)
              scale: down ? 0.97 : 1
              Behavior on radius { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
              Behavior on scale {
                NumberAnimation {
                  duration: root.springy ? 360 : 200
                  easing.type: root.springy ? Easing.OutBack : Easing.OutCubic
                  easing.overshoot: 2.2
                }
              }

              Behavior on y {
                enabled: root.conf.animation.enabled
                NumberAnimation {
                  duration: root.springy ? 420 : 260
                  easing.type: root.springy ? Easing.OutBack : Easing.BezierSpline
                  easing.overshoot: 1.4
                  easing.bezierCurve: root.emphasized
                }
              }
              Behavior on height {
                enabled: root.conf.animation.enabled
                NumberAnimation {
                  duration: root.springy ? 420 : 260
                  easing.type: root.springy ? Easing.OutBack : Easing.BezierSpline
                  easing.overshoot: 1.4
                  easing.bezierCurve: root.emphasized
                }
              }
            }
          }

          ListView {
            id: list

            anchors.fill: parent
            clip: true
            model: root.results
            currentIndex: root.cur
            spacing: root.conf.list.row_gap
            boundsBehavior: Flickable.StopAtBounds
            highlightMoveDuration: 0

            highlight: root.md ? hlComp : null
            highlightFollowsCurrentItem: false

            
            NumberAnimation {
              id: scrollAnim
              target: list
              property: "contentY"
              duration: 280
              easing.type: Easing.BezierSpline
              easing.bezierCurve: root.emphasized
            }

            onCurrentIndexChanged: {
              if (!(root.md && root.conf.animation.enabled)) {
                positionViewAtIndex(currentIndex, ListView.Contain);
                return;
              }

              var top = list.contentY;
              var rowY = currentIndex * root.pitch;
              var rowH = root.conf.list.row_height;
              var tgt = top;

              if (rowY < top) tgt = rowY;
              else if (rowY + rowH > top + list.height) tgt = rowY + rowH - list.height;

              tgt = Math.max(0, Math.min(Math.max(0, list.contentHeight - list.height), tgt));

              if (Math.abs(tgt - top) > 0.5) {
                scrollAnim.stop();
                scrollAnim.to = tgt;
                scrollAnim.start();
              }
            }

            delegate: Item {
              id: row

              required property var modelData
              required property int index

              readonly property bool sel:
              ListView.isCurrentItem
              readonly property bool pressed: ma.pressed

              width: list.width
              height: root.conf.list.row_height

              
              function play() {
                if (!root.md || !root.conf.animation.enabled) return;
                enter.restart();
              }
              Component.onCompleted: play()
              Connections {
                target: root
                function onOpenGenChanged() { row.play() }
              }

              SequentialAnimation {
                id: enter
                ScriptAction {
                  script: {
                    fx.opacity = root.staggerOn ? 0 : 0.4;
                    shift.y = root.staggerOn ? 18 : 5;
                  }
                }
                PauseAnimation { duration: root.staggerOn ? Math.min(row.index, 8) * 28 : 0 }
                ParallelAnimation {
                  NumberAnimation { target: fx; property: "opacity"; to: 1
                                    duration: root.staggerOn ? 260 : 130
                                    easing.type: Easing.OutCubic }
                  NumberAnimation { target: shift; property: "y"; to: 0
                                    duration: root.staggerOn ? 460 : 180
                                    easing.type: root.springy ? Easing.OutBack : Easing.OutCubic
                                    easing.overshoot: 1.7 }
                }
              }

              Item {
                id: fx
                anchors.fill: parent
                transform: Translate { id: shift }

                scale: root.md && ma.pressed ? 0.97 : 1
                Behavior on scale {
                  enabled: root.md
                  NumberAnimation {
                    duration: root.springy ? 360 : 200
                    easing.type: root.springy ? Easing.OutBack : Easing.OutCubic
                    easing.overshoot: 2.2
                  }
                }

                
                Rectangle {
                  anchors.fill: parent
                  radius: root.md
                    ? Math.min(root.conf.list.row_radius, height / 2)
                    : root.conf.list.row_radius
                  color: root.md
                    ? root.layered(root.pal.bg, root.pal.fg, 0.08)
                    : root.pal.hover
                  opacity: ma.containsMouse && !row.sel ? 1 : 0
                  Behavior on opacity { NumberAnimation { duration: 120 } }
                }

                
                Rectangle {
                  anchors.fill: parent
                  radius: root.conf.list.row_radius
                  visible: row.sel && !root.md

                  gradient: Gradient {
                    orientation: Gradient.Horizontal

                    GradientStop {
                      position: 0.0
                      color: root.pal.selected_from
                    }

                    GradientStop {
                      position: 1.0
                      color: root.pal.selected_to
                    }
                  }
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: root.conf.list.padding_x
                  anchors.rightMargin: root.conf.list.padding_x + (root.md ? 40 : 0)
                  spacing: root.conf.list.icon_gap

                  Item {
                    id: lead
                    visible: root.conf.list.show_icons

                    Layout.alignment: Qt.AlignVCenter

                    Layout.preferredWidth: row.modelData.img
                      ? root.conf.list.thumb_width
                      : (root.md ? root.conf.list.icon_size + 14 : root.conf.list.icon_size)

                    Layout.preferredHeight: row.modelData.img
                      ? root.conf.list.row_height - 8
                      : (root.md ? root.conf.list.icon_size + 14 : root.conf.list.icon_size)

                    
                    scale: root.md && row.sel ? 1.08 : 1
                    Behavior on scale {
                      enabled: root.md
                      NumberAnimation {
                        duration: root.springy ? 420 : 220
                        easing.type: root.springy ? Easing.OutBack : Easing.OutCubic
                        easing.overshoot: 2.6
                      }
                    }

                    
                    Rectangle {
                      anchors.fill: parent
                      visible: root.md && !row.modelData.img
                      radius: width / 2
                      color: row.sel
                        ? root.layered(root.pal.selected_from, root.pal.selected_fg, 0.14)
                        : root.pal.surface
                      Behavior on color { ColorAnimation { duration: 200 } }
                    }

                    Text {
                      anchors.centerIn: parent

                      visible: !row.modelData.img
                        || thumb.status !== Image.Ready

                      text: row.modelData.img
                        ? root.conf.list.image_icon
                        : root.conf.list.text_icon

                      color: row.sel
                        ? root.pal.selected_fg
                        : root.pal.accent
                      Behavior on color { enabled: root.md; ColorAnimation { duration: 200 } }

                      font.family: root.iconFont
                      font.pixelSize:
                      root.conf.list.icon_size * 0.8
                    }

                    
                    Item {
                      id: thumbMask
                      anchors.fill: parent
                      visible: false
                      layer.enabled: true
                      Rectangle {
                        anchors.fill: parent
                        radius: Math.min(14, height / 2)
                        color: "black"
                      }
                    }

                    Image {
                      id: thumb

                      anchors.fill: parent
                      visible: row.modelData.img
                      clip: true
                      asynchronous: true
                      fillMode: Image.PreserveAspectCrop

                      sourceSize: Qt.size(
                        root.conf.list.thumb_width * 2,
                        root.conf.list.row_height * 2
                      )

                      source: row.modelData.img
                        ? "file://" + root.cacheDir
                      + "/" + row.modelData.id + ".img"
                        : ""

                      
                      opacity: status === Image.Ready ? 1 : 0
                      Behavior on opacity { enabled: root.md; NumberAnimation { duration: 220 } }

                      layer.enabled: root.md
                      layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: thumbMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                      }
                    }
                  }

                  Text {
                    Layout.fillWidth: true

                    text: row.modelData.name
                    elide: Text.ElideRight
                    maximumLineCount: 1

                    color: row.sel
                      ? root.pal.selected_fg
                      : root.pal.fg
                    Behavior on color { enabled: root.md; ColorAnimation { duration: 200 } }

                    font.family: root.fontFamily
                    font.pixelSize: root.conf.font.size

                    font.weight: row.sel
                      ? root.conf.font.selected_weight_n
                      : root.conf.font.weight_n

                    font.italic: root.conf.font.italic
                    font.letterSpacing:
                    root.conf.font.letter_spacing
                  }
                }
              }

              MouseArea {
                id: ma

                anchors.fill: parent
                hoverEnabled: true

                onPositionChanged: {
                  if (root.conf.behavior.hover_select) {
                    root.cur = row.index;
                  }
                }

                onClicked: root.pick(row.modelData)
              }

              
              Rectangle {
                id: delBtn

                visible: root.md && opacity > 0.01
                anchors.right: parent.right
                anchors.rightMargin: root.conf.list.padding_x - 4
                anchors.verticalCenter: parent.verticalCenter

                width: 32
                height: 32
                radius: delTap.pressed ? 8 : 16
                Behavior on radius { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                color: delTap.pressed
                  ? root.pal.urgent
                  : root.layered(root.pal.selected_from, root.pal.urgent,
                                 delHover.hovered ? 0.28 : 0)
                Behavior on color { ColorAnimation { duration: 140 } }

                opacity: row.sel ? 1 : 0
                scale: delTap.pressed ? 0.85 : (row.sel ? 1 : 0.4)
                Behavior on opacity { NumberAnimation { duration: 150 } }
                Behavior on scale {
                  NumberAnimation {
                    duration: root.springy ? 380 : 200
                    easing.type: root.springy ? Easing.OutBack : Easing.OutCubic
                    easing.overshoot: 2.6
                  }
                }

                Text {
                  anchors.centerIn: parent
                  text: ""
                  color: delTap.pressed ? root.pal.bg
                       : (delHover.hovered ? root.pal.urgent : root.pal.selected_fg)
                  Behavior on color { ColorAnimation { duration: 140 } }
                  font.family: root.iconFont
                  font.pixelSize: 14
                }

                HoverHandler { id: delHover }
                TapHandler {
                  id: delTap
                  onTapped: root.del(row.modelData)
                }
              }
            }
          }

          Rectangle {
            visible: root.conf.list.scrollbar
              && list.visibleArea.heightRatio < 1

            x: parent.width + Math.max(
              0,
              Math.min(
                root.conf.list.scrollbar_gap,
                root.conf.window.padding - width
              )
            )

            y: list.visibleArea.yPosition * parent.height

            width: 3

            height: Math.max(
              16,
              list.visibleArea.heightRatio * parent.height
            )

            radius: 2
            color: root.md ? root.pal.accent : root.pal.muted
            Behavior on color { enabled: root.md; ColorAnimation { duration: 400 } }
            opacity: 0.5
          }
        }

        
        Item {
          id: empty
          visible: root.results.length === 0
          width: parent.width
          height: root.conf.list.row_height

          onVisibleChanged: {
            if (visible && root.md && root.conf.animation.enabled) emptyAnim.restart();
          }
          ParallelAnimation {
            id: emptyAnim
            NumberAnimation { target: emptyText; property: "opacity"; from: 0; to: 1; duration: 220 }
            NumberAnimation { target: emptyText; property: "scale"; from: 0.85; to: 1; duration: 420
                              easing.type: Easing.OutBack; easing.overshoot: 2 }
          }

          Text {
            id: emptyText
            anchors.centerIn: parent

            text: root.conf.list.empty_text
            color: root.pal.muted
            Behavior on color { enabled: root.md; ColorAnimation { duration: 400 } }

            font.family: root.fontFamily
            font.pixelSize: root.conf.font.size
          }
        }

        Text {
          visible: root.warnings.length > 0
          width: parent.width

          maximumLineCount: 1
          elide: Text.ElideRight

          color: root.pal.urgent
          font.family: root.fontFamily

          font.pixelSize: Math.max(
            8,
            root.conf.font.size - 3
          )

          text: root.warnings.length > 0
            ? "config: " + root.warnings[0]
          + (
            root.warnings.length > 1
              ? "  (+"
            + (root.warnings.length - 1)
            + " more)"
              : ""
          )
            : ""
        }
      }
    }
  }
}
