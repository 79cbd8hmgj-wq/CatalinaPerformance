#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MAIN="$ROOT_DIR/app/CatalinaPerformance/Sources/CatalinaPerformance/main.swift"
FOREGROUND="$ROOT_DIR/app/CatalinaPerformance/Sources/CatalinaPerformance/ForegroundSessionPanelController.swift"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  file=$1
  pattern=$2
  message=$3
  grep -F "$pattern" "$file" >/dev/null 2>&1 || fail "$message"
}

excludes() {
  file=$1
  pattern=$2
  message=$3
  if grep -F "$pattern" "$file" >/dev/null 2>&1; then
    fail "$message"
  fi
}

contains "$MAIN" 'final class FlippedDocumentView: NSView' 'Advanced scrolling must use a flipped document view so content begins at the top.'
contains "$MAIN" 'documentView.addSubview(stack)' 'Advanced stack must be pinned inside a dedicated document view.'
excludes "$MAIN" 'scrollView.documentView = stack' 'Advanced stack must not be used directly as the scroll-view document view.'
excludes "$MAIN" 'box.contentView = stack' 'Section stacks must not replace the NSBox content view.'
contains "$MAIN" 'boxContentView.addSubview(stack)' 'Section stack must be pinned to the NSBox content view.'
excludes "$FOREGROUND" 'box.contentView = contentStack' 'Foreground section stack must not replace the NSBox content view.'
contains "$FOREGROUND" 'boxContentView.addSubview(contentStack)' 'Foreground section stack must be pinned to the NSBox content view.'
contains "$MAIN" 'private func updateAdvancedDocumentSize()' 'Advanced document view must receive an explicit frame height so NSScrollView can scroll on Catalina.'
contains "$MAIN" 'documentView.frame = NSRect' 'Advanced document view frame must be updated from the stack fitting height.'
contains "$MAIN" 'func windowDidResize' 'Advanced document sizing must be refreshed when its window resizes.'
excludes "$MAIN" 'documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)' 'The Advanced document view must not be constrained to the clip view because that prevents a larger scrollable frame on Catalina.'
contains "$FOREGROUND" 'func updateApplicationListDocumentSize()' 'The nested application list must explicitly size its document view.'
excludes "$FOREGROUND" 'applicationsDocumentView.topAnchor.constraint(equalTo: appScrollView.contentView.topAnchor)' 'The application-list document view must not be constrained to its clip view.'

printf 'PASS: Advanced layout source contract\n'
