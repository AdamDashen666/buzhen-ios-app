# CodexPad Design

## Goal
Build an iPad-native coding agent that edits only a folder explicitly authorized through the Files picker, using an OpenAI-compatible Responses API agent loop.

## Architecture
- **SwiftUI shell:** three-column project tree, text editor, and agent chat.
- **Workspace service:** security-scoped folder bookmark, `NSFileCoordinator`, path traversal and symlink protection, UTF-8 text operations.
- **Agent:** Responses API function calling for list/read/search/write/create/delete/move. Read-only tools execute immediately; mutations pause for review unless Auto Apply is enabled.
- **Security:** API key in Keychain, HTTPS-only endpoint, common secret-file blocking by default, no shell/process execution.
- **Core package:** platform-neutral path safety, diffing, tool schemas, response parsing, and pending-change models with Linux-verifiable tests.

## Constraints
- iPadOS 18+; iPad only.
- No third-party dependencies.
- No arbitrary filesystem access, shell, local git, package manager, or `xcodebuild` on iPadOS.
- Default model is `gpt-6-astra`; base URL/model/reasoning are user configurable.
