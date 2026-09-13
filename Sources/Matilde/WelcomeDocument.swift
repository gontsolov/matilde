import Foundation

enum WelcomeDocument {
    static let title = "Your next great piece starts here"
    static let goal = "Find something worth saying."
    static let text = """
    Welcome to Matilde. A little room to think clearly, follow an idea, and write something you're proud of.

    ## Try another direction
    Branch a draft to explore a different opening, a bolder argument, or a completely different ending. Your original stays yours. Both versions stay editable.

    ## See the bigger picture
    Pinch out or press ⌘0 to see your drafts together on the canvas. Open any page to keep writing.

    ## Keep your hands on the words
    Markdown turns into formatting as you write: headings, **bold**, *italics*, lists, and `---` for a quiet break. Use ⌘B and ⌘I for emphasis.

    Paste an image onto the page, or paste a URL over selected words to link them. Use ⌘K to add or edit a link.

    ## Your words, your files
    Changes save automatically. Your writing lives in ordinary Markdown files on your Mac.

    ---

    Try it: branch this page with ⇧⌘B and rewrite the opening. Or press ⌘N for a fresh page.

    Start messy. Follow the interesting bit. Make it yours.
    """
}

extension Workspace {
    func welcomeDocument(explicit: Bool = false) throws -> Draft? {
        let drafts = try scan().drafts
        if explicit, let id = try state("welcomeDraft"), let existing = drafts.first(where: { $0.id == id }) {
            return existing
        }
        if !explicit {
            guard try state("welcomeSeeded") == nil else { return nil }
            // Remember existing workspaces too: deleting their last file must not
            // unexpectedly create an onboarding document later.
            guard drafts.isEmpty else { try setState("welcomeSeeded", "true"); return nil }
        }
        var name = WelcomeDocument.title
        var number = 2
        while FileManager.default.fileExists(atPath: try url(for: filePath(name: name, folder: "")).path) {
            name = "\(WelcomeDocument.title) \(number)"; number += 1
        }
        let draft = try create(name: name, folder: "", goal: WelcomeDocument.goal, text: WelcomeDocument.text)
        try setState("welcomeDraft", draft.id)
        try setState("welcomeSeeded", "true")
        return draft
    }
}
