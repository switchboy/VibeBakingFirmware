package org.vibebaking.launcher.logic;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Minimal JSON parser (objects/arrays/strings/numbers/bools/null) — no external deps. */
public final class Json {

    private Json() {}

    public static Object parse(String text) {
        Parser p = new Parser(text);
        p.skipWs();
        Object v = p.value();
        p.skipWs();
        if (p.pos < p.src.length()) throw new IllegalArgumentException("trailing garbage at " + p.pos);
        return v;
    }

    @SuppressWarnings("unchecked")
    public static Map<String, Object> object(Object v) {
        if (v instanceof Map) return (Map<String, Object>) v;
        throw new IllegalArgumentException("not a JSON object");
    }

    @SuppressWarnings("unchecked")
    public static List<Object> array(Object v) {
        if (v instanceof List) return (List<Object>) v;
        throw new IllegalArgumentException("not a JSON array");
    }

    public static String str(Object v) { return v == null ? "" : String.valueOf(v); }

    public static Double num(Object v) {
        if (v instanceof Double) return (Double) v;
        if (v instanceof Long) return ((Long) v).doubleValue();
        return null;
    }

    private static final class Parser {
        final String src;
        int pos;
        Parser(String s) { src = s; }

        void skipWs() {
            while (pos < src.length() && Character.isWhitespace(src.charAt(pos))) pos++;
        }

        Object value() {
            skipWs();
            if (pos >= src.length()) throw new IllegalArgumentException("unexpected end");
            char c = src.charAt(pos);
            switch (c) {
                case '{': return objectVal();
                case '[': return arrayVal();
                case '"': return stringVal();
                case 't': expect("true"); return Boolean.TRUE;
                case 'f': expect("false"); return Boolean.FALSE;
                case 'n': expect("null"); return null;
                default: return numberVal();
            }
        }

        Map<String, Object> objectVal() {
            Map<String, Object> m = new LinkedHashMap<>();
            pos++; // '{'
            skipWs();
            if (pos < src.length() && src.charAt(pos) == '}') { pos++; return m; }
            while (true) {
                skipWs();
                String k = stringVal();
                skipWs();
                if (pos >= src.length() || src.charAt(pos) != ':') throw new IllegalArgumentException("expected ':'");
                pos++;
                m.put(k, value());
                skipWs();
                if (pos < src.length() && src.charAt(pos) == ',') { pos++; continue; }
                if (pos < src.length() && src.charAt(pos) == '}') { pos++; return m; }
                throw new IllegalArgumentException("expected ',' or '}'");
            }
        }

        List<Object> arrayVal() {
            List<Object> a = new ArrayList<>();
            pos++; // '['
            skipWs();
            if (pos < src.length() && src.charAt(pos) == ']') { pos++; return a; }
            while (true) {
                a.add(value());
                skipWs();
                if (pos < src.length() && src.charAt(pos) == ',') { pos++; continue; }
                if (pos < src.length() && src.charAt(pos) == ']') { pos++; return a; }
                throw new IllegalArgumentException("expected ',' or ']'");
            }
        }

        String stringVal() {
            if (src.charAt(pos) != '"') throw new IllegalArgumentException("expected string");
            pos++;
            StringBuilder sb = new StringBuilder();
            while (pos < src.length()) {
                char c = src.charAt(pos++);
                if (c == '"') return sb.toString();
                if (c == '\\') {
                    char e = src.charAt(pos++);
                    switch (e) {
                        case 'n': sb.append('\n'); break;
                        case 't': sb.append('\t'); break;
                        case 'r': sb.append('\r'); break;
                        case '"': sb.append('"'); break;
                        case '\\': sb.append('\\'); break;
                        case '/': sb.append('/'); break;
                        case 'b': sb.append('\b'); break;
                        case 'f': sb.append('\f'); break;
                        case 'u': sb.append((char) Integer.parseInt(src.substring(pos, pos + 4), 16)); pos += 4; break;
                        default: throw new IllegalArgumentException("bad escape " + e);
                    }
                } else {
                    sb.append(c);
                }
            }
            throw new IllegalArgumentException("unterminated string");
        }

        Object numberVal() {
            int start = pos;
            while (pos < src.length() && isNumChar(src.charAt(pos))) pos++;
            String n = src.substring(start, pos);
            if (n.isEmpty()) throw new IllegalArgumentException("expected number at " + start);
            if (n.contains(".") || n.contains("e") || n.contains("E")) return Double.parseDouble(n);
            return Long.parseLong(n);
        }

        boolean isNumChar(char c) {
            return c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E' || (c >= '0' && c <= '9');
        }

        void expect(String word) {
            if (!src.startsWith(word, pos)) throw new IllegalArgumentException("expected " + word);
            pos += word.length();
        }
    }
}
