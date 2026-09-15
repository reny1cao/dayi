import PolishCore
import AppKit
import SwiftUI

/// Three scenes, each with one job.
///
/// The window is opened rarely — to rescue a result that could not be written back, to read
/// one that was, or to fix a precondition — so it holds no configuration and no primary
/// action. The primary action is a hot key pressed inside somebody else's application, and
/// the two surfaces that have to be reachable at that moment are the menu bar and the HUD.
@main
struct TextPolishApp: App {
    @State private var model = AppModel()

    init() {
        if UpdateController.isAvailable { UpdateController.shared.start() }
    }

    var body: some Scene {
        // The title bar is `navigationTitle` + `navigationSubtitle` from inside the view: it
        // names the current list and its size, which is what a toolbar title should say when
        // the window has no action to offer.
        Window(L10n.tr("活动"), id: DayiScene.activityWindow) {
            ActivityWindow(model: model)
                .environment(\.locale, L10n.locale)
        }
        .defaultSize(width: Metric.windowWidth, height: Metric.windowHeight)
        .commands { AppCommands() }

        Settings {
            SettingsScene(model: model)
                .environment(\.locale, L10n.locale)
        }

        MenuBarExtra(isInserted: Binding(get: { model.menuBarVisible },
                                        set: { model.menuBarVisible = $0 })) {
            MenuBarMenu(model: model)
                .environment(\.locale, L10n.locale)
        } label: {
            MenuBarLabel(model: model)
        }
        // Not negotiable: the title block stacks a semibold line over a logo and a monospaced
        // model id, and every waiting result carries a second line of preview text. An
        // `NSMenuItem` can hold neither, so the default `.menu` style would flatten both.
        .menuBarExtraStyle(.window)
    }
}
