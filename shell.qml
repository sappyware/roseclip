import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "config.js" as Config
import "search.js" as Search

ShellRoot {
  id: root

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string cfgHome: Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")
  readonly property string configPath: Quickshell.env("ROSECLIP_CONFIG") || (cfgHome + "/roseclip/config.toml")
  readonly property string cacheDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/roseclip"

  property var loaded: Config.load("")
  property bool hasGoodConfig: false

  readonly property var conf: loaded.conf
  readonly property var pal: loaded.pal
  readonly property var warnings: loaded.warnings

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

  function open(reload) {
    if (reload) cfgFile.reload();

    input.text = "";
    query = "";
    cur = 0;
    shown = true;
    listProc.running = true;

    if (conf.animation.enabled) appear.restart();

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
    interval: 180
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

    if (conf.behavior.mode !== "daemon") open(false);
  }

  PanelWindow {
    id: win

    visible: root.shown
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
      opacity: root.conf.window.dim
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

      border.width: root.conf.window.border_width
      border.color: root.pal.border

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

      ParallelAnimation {
        id: appear

        NumberAnimation {
          target: card
          property: "opacity"
          from: 0
          to: 1
          duration: root.conf.animation.duration_ms
          easing.type: Easing.OutCubic
        }

        NumberAnimation {
          target: card
          property: "scale"
          from: 0.97
          to: 1
          duration: root.conf.animation.duration_ms
          easing.type: Easing.OutCubic
        }
      }

      Column {
        id: col

        x: root.conf.window.padding
        y: root.conf.window.padding

        width: card.width - root.conf.window.padding * 2
        spacing: root.conf.window.gap

        Rectangle {
          width: parent.width
          height: root.conf.search.height
          radius: root.conf.search.radius

          color: root.pal.surface

          border.width: root.conf.search.border_width
          border.color: root.pal.accent

          Text {
            id: sIcon

            anchors.left: parent.left
            anchors.leftMargin: root.conf.search.padding_x
            anchors.verticalCenter: parent.verticalCenter

            text: root.conf.search.icon
            color: root.pal.selected_from

            font.family: root.fontFamily
            font.pixelSize: root.conf.search.icon_size
          }

          TextInput {
            id: input

            anchors.left: sIcon.right
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: root.conf.search.padding_x
            anchors.verticalCenter: parent.verticalCenter

            clip: true
            focus: true

            color: root.pal.fg
            selectionColor: root.pal.selected_from
            selectedTextColor: root.pal.selected_fg

            font.family: root.fontFamily
            font.pixelSize: root.conf.font.size
            font.weight: root.conf.font.weight_n
            font.italic: root.conf.font.italic
            font.letterSpacing: root.conf.font.letter_spacing

            onTextChanged: root.query = text

            Keys.onPressed: function(event) {
              root.handleKey(event);
            }

            Text {
              anchors.fill: parent
              visible: input.text === ""

              verticalAlignment: Text.AlignVCenter
              text: root.conf.search.placeholder
              color: root.pal.muted
              font: input.font
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
              duration: root.conf.animation.resize_ms
              easing.type: Easing.OutCubic
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

            onCurrentIndexChanged: {
              positionViewAtIndex(
                currentIndex,
                ListView.Contain
              );
            }

            delegate: Item {
              id: row

              required property var modelData
              required property int index

              readonly property bool sel:
              ListView.isCurrentItem

              width: list.width
              height: root.conf.list.row_height

              Rectangle {
                anchors.fill: parent
                radius: root.conf.list.row_radius
                color: root.pal.hover
                visible: ma.containsMouse && !row.sel
              }

              Rectangle {
                anchors.fill: parent
                radius: root.conf.list.row_radius
                visible: row.sel

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
                anchors.rightMargin: root.conf.list.padding_x
                spacing: root.conf.list.icon_gap

                Item {
                  visible: root.conf.list.show_icons

                  Layout.alignment: Qt.AlignVCenter

                  Layout.preferredWidth: row.modelData.img
                    ? root.conf.list.thumb_width
                    : root.conf.list.icon_size

                  Layout.preferredHeight: row.modelData.img
                    ? root.conf.list.row_height - 8
                    : root.conf.list.icon_size

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

                    font.family: root.fontFamily
                    font.pixelSize:
                    root.conf.list.icon_size * 0.8
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
            color: root.pal.muted
            opacity: 0.5
          }
        }

        Item {
          visible: root.results.length === 0
          width: parent.width
          height: root.conf.list.row_height

          Text {
            anchors.centerIn: parent

            text: root.conf.list.empty_text
            color: root.pal.muted

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
