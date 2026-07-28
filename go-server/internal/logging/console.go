package logging

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ConsoleHandler writes one human-readable line per record without JSON
// quotation marks. This keeps logs readable in hosting panels that HTML-escape
// stdout but fail to decode entities such as &quot; when rendering them.
type ConsoleHandler struct {
	writer io.Writer
	level  slog.Leveler
	mutex  *sync.Mutex
	attrs  []slog.Attr
	groups []string
}

func NewConsoleHandler(writer io.Writer, level slog.Leveler) *ConsoleHandler {
	if level == nil {
		level = slog.LevelInfo
	}
	return &ConsoleHandler{
		writer: writer,
		level:  level,
		mutex:  &sync.Mutex{},
	}
}

func (h *ConsoleHandler) Enabled(_ context.Context, level slog.Level) bool {
	return level >= h.level.Level()
}

func (h *ConsoleHandler) Handle(_ context.Context, record slog.Record) error {
	var builder strings.Builder
	builder.WriteString(record.Time.Format("2006-01-02 15:04:05"))
	builder.WriteString(" [")
	builder.WriteString(record.Level.String())
	builder.WriteString("] ")
	appendDisplayText(&builder, record.Message, false)
	for _, attr := range h.attrs {
		h.appendAttr(&builder, h.groups, attr)
	}
	record.Attrs(func(attr slog.Attr) bool {
		h.appendAttr(&builder, h.groups, attr)
		return true
	})
	builder.WriteByte('\n')

	h.mutex.Lock()
	defer h.mutex.Unlock()
	_, err := io.WriteString(h.writer, builder.String())
	return err
}

func (h *ConsoleHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	clone := h.clone()
	clone.attrs = append(clone.attrs, attrs...)
	return clone
}

func (h *ConsoleHandler) WithGroup(name string) slog.Handler {
	if name == "" {
		return h
	}
	clone := h.clone()
	clone.groups = append(clone.groups, name)
	return clone
}

func (h *ConsoleHandler) clone() *ConsoleHandler {
	clone := *h
	clone.attrs = append([]slog.Attr(nil), h.attrs...)
	clone.groups = append([]string(nil), h.groups...)
	return &clone
}

func (h *ConsoleHandler) appendAttr(
	builder *strings.Builder,
	groups []string,
	attr slog.Attr,
) {
	value := attr.Value.Resolve()
	if value.Kind() == slog.KindGroup {
		nextGroups := groups
		if attr.Key != "" {
			nextGroups = append(append([]string(nil), groups...), attr.Key)
		}
		for _, child := range value.Group() {
			h.appendAttr(builder, nextGroups, child)
		}
		return
	}
	if attr.Key == "" {
		return
	}
	keyParts := append(append([]string(nil), groups...), attr.Key)
	appendField(builder, strings.Join(keyParts, "."), formatValue(value))
}

func formatValue(value slog.Value) string {
	switch value.Kind() {
	case slog.KindString:
		return value.String()
	case slog.KindBool:
		return strconv.FormatBool(value.Bool())
	case slog.KindInt64:
		return strconv.FormatInt(value.Int64(), 10)
	case slog.KindUint64:
		return strconv.FormatUint(value.Uint64(), 10)
	case slog.KindFloat64:
		return strconv.FormatFloat(value.Float64(), 'g', -1, 64)
	case slog.KindDuration:
		return value.Duration().String()
	case slog.KindTime:
		return value.Time().Format(time.RFC3339Nano)
	default:
		return fmt.Sprint(value.Any())
	}
}

func appendField(builder *strings.Builder, key, value string) {
	if builder.Len() > 0 {
		builder.WriteByte(' ')
	}
	builder.WriteString(key)
	builder.WriteString("=[")
	appendDisplayText(builder, value, true)
	builder.WriteByte(']')
}

func appendDisplayText(builder *strings.Builder, value string, escapeBracket bool) {
	for _, character := range value {
		switch character {
		case '\\':
			builder.WriteString(`\\`)
		case ']':
			if escapeBracket {
				builder.WriteString(`\]`)
			} else {
				builder.WriteRune(character)
			}
		case '"', '\'':
			// Hosting panels commonly HTML-escape quotes without decoding
			// them again. Quotes are unnecessary in this bracketed format.
			continue
		case '&':
			builder.WriteRune('＆')
		case '<':
			builder.WriteRune('＜')
		case '>':
			builder.WriteRune('＞')
		case '\r':
			builder.WriteString(`\r`)
		case '\n':
			builder.WriteString(`\n`)
		case '\t':
			builder.WriteString(`\t`)
		default:
			builder.WriteRune(character)
		}
	}
}
