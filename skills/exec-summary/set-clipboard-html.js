// Put an HTML fragment on the macOS clipboard as BOTH public.html and plain text.
// The osascript «data HTML…» one-liner sets only the HTML flavor, and paste handlers
// (Slack's among them — measured) can refuse a clipboard with no plain-text type.
// Usage: osascript -l JavaScript set-clipboard-html.js <file.html> <file.txt>
ObjC.import('AppKit')

function run(argv) {
  const read = (p) =>
    ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null))
  const html = read(argv[0])
  const text = read(argv[1])
  if (!html || !text) throw new Error('unreadable input file(s): ' + argv.join(', '))
  const pb = $.NSPasteboard.generalPasteboard
  pb.clearContents
  pb.setStringForType(html, $.NSPasteboardTypeHTML)
  pb.setStringForType(text, $.NSPasteboardTypeString)
  return 'clipboard set: html=' + html.length + ' chars, text=' + text.length + ' chars'
}
