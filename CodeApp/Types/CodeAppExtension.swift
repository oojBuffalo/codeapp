//
//  CodeAppExtension.swift
//  Code
//
//  Created by Ken Chung on 14/11/2022.
//

import Foundation

class CodeAppExtension {
    class Contribution {
        var panel: PanelManager
        var toolBar: ToolbarManager
        var editorProvider: EditorProviderManager
        var statusBar: StatusBarManager
        var activityBar: ActivityBarManager

        init(
            panel: PanelManager,
            toolbarItem: ToolbarManager,
            editorProvider: EditorProviderManager,
            statusBarManager: StatusBarManager,
            activityBarManager: ActivityBarManager
        ) {
            self.panel = panel
            self.toolBar = toolbarItem
            self.editorProvider = editorProvider
            self.statusBar = statusBarManager
            self.activityBar = activityBarManager
        }
    }

    func onInitialize(
        app: MainApp,
        contribution: CodeAppExtension.Contribution
    ) {

    }

    func onWorkSpaceStorageChanged(newUrl: URL) {

    }

}
