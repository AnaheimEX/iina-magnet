```markdown
# iina-magnet Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches you the core development patterns and conventions used in the `iina-magnet` repository, a Swift codebase with no detected framework. You'll learn about file organization, import/export styles, commit conventions, and how to structure and run tests. This guide is ideal for contributors aiming for consistency and maintainability in this project.

## Coding Conventions

### File Naming
- **PascalCase** is used for file names.
  - Example: `MagnetManager.swift`, `WindowController.swift`

### Import Style
- **Relative imports** are used.
  - Example:
    ```swift
    import MagnetCore
    import Utilities
    ```

### Export Style
- **Named exports** are preferred.
  - Example:
    ```swift
    public class MagnetManager { ... }
    public struct MagnetOptions { ... }
    ```

### Commit Patterns
- **Mixed commit types** (features, fixes, CI, etc.)
- **Prefixes:** Some commits use `ci` as a prefix for continuous integration changes.
- **Average commit message length:** ~59 characters.
  - Example:
    ```
    ci: update GitHub Actions workflow for Swift 5.7
    ```

## Workflows

### Continuous Integration Updates
**Trigger:** When updating CI configurations or workflows.
**Command:** `/ci-update`

1. Make necessary changes to CI configuration files (e.g., GitHub Actions).
2. Prefix your commit message with `ci:`.
3. Push changes to the repository.
4. Ensure CI passes on the pull request.

### Adding a New Feature
**Trigger:** When implementing a new feature.
**Command:** `/add-feature`

1. Create a new Swift file using PascalCase.
2. Use relative imports for dependencies.
3. Export your class/struct using named exports.
4. Write or update corresponding test files (`*.test.*`).
5. Commit with a descriptive message.
6. Open a pull request for review.

### Writing Tests
**Trigger:** When adding or updating tests.
**Command:** `/write-test`

1. Create or update test files matching the `*.test.*` pattern.
2. Follow the project's coding conventions in test code.
3. Run tests locally (framework unknown; see project documentation or scripts).
4. Commit and push your changes.

## Testing Patterns

- **Test files** follow the `*.test.*` naming pattern (e.g., `MagnetManager.test.swift`).
- **Testing framework:** Not explicitly detected; refer to project documentation or inspect test files for clues.
- **Test code** should follow the same coding conventions as production code (PascalCase files, relative imports, named exports).

## Commands
| Command        | Purpose                                                |
|----------------|--------------------------------------------------------|
| /ci-update     | Update CI configurations and workflows                 |
| /add-feature   | Add a new feature following project conventions        |
| /write-test    | Add or update tests using the project's test patterns  |
```
