# Markdown Standards

## Critical Rules (Prevent CI Failures)

### Always Include Language in Code Blocks

````markdown
<!-- Wrong -->
```
code here
```

<!-- Correct -->
```javascript
code here
```
````

**Default to `text` if unsure about the language.**

### Use Proper Headings (Not Bold Text)

```markdown
<!-- Wrong -->
**Section Title**

<!-- Correct -->
### Section Title
```

### Use Sequential List Numbering

```markdown
<!-- Wrong -->
4. Item
5. Item

<!-- Correct -->
1. Item
2. Item
```

## Common Language Specifiers

- `javascript`, `typescript`, `json`, `bash`, `yaml`, `text`
- `python`, `ruby`, `go`, `rust`, `html`, `css`, `sql`
- `console` for terminal output, `diff` for file changes

## Note

Markdownlint automatically fixes most issues via the global Stop hook. These rules prevent the most common violations that hooks can't easily fix.
