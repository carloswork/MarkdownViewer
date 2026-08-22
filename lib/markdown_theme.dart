import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'blocks.dart';

/// Reading colours. Kept separate from [ThemeData] because the Markdown configs
/// need concrete colours at build time, not a resolved widget theme.
class ReaderPalette {
  const ReaderPalette({
    required this.isDark,
    required this.background,
    required this.surface,
    required this.text,
    required this.muted,
    required this.link,
    required this.codeBackground,
    required this.codeBorder,
    required this.quoteBar,
    required this.quoteText,
    required this.rule,
    required this.tableHeader,
    required this.highlightTheme,
  });

  final bool isDark;
  final Color background;
  final Color surface;
  final Color text;
  final Color muted;
  final Color link;
  final Color codeBackground;
  final Color codeBorder;
  final Color quoteBar;
  final Color quoteText;
  final Color rule;
  final Color tableHeader;

  /// highlight.js token styles. Pulled off `PreConfig` so we get the bundled
  /// a11y themes without taking a direct dependency on flutter_highlight.
  final Map<String, TextStyle> highlightTheme;

  /// Warm paper. Pure white is tiring on a phone held close.
  static final ReaderPalette light = ReaderPalette(
    isDark: false,
    background: const Color(0xFFFBFAF7),
    surface: const Color(0xFFF2F0EA),
    text: const Color(0xFF1C1B19),
    muted: const Color(0xFF6B675F),
    link: const Color(0xFF0B5FA5),
    codeBackground: const Color(0xFFF3F1EB),
    codeBorder: const Color(0xFFE2DED4),
    quoteBar: const Color(0xFFD6D1C4),
    quoteText: const Color(0xFF56524A),
    rule: const Color(0xFFE2DED4),
    tableHeader: const Color(0xFFF0EDE6),
    highlightTheme: const PreConfig().theme,
  );

  /// Not pure black: OLED black plus white text creates halation on serif-ish
  /// body text. Slightly lifted background, slightly warm off-white text.
  static final ReaderPalette dark = ReaderPalette(
    isDark: true,
    background: const Color(0xFF15161A),
    surface: const Color(0xFF1E2026),
    text: const Color(0xFFDFDDD7),
    muted: const Color(0xFF938F88),
    link: const Color(0xFF7FB3E8),
    codeBackground: const Color(0xFF1B1D23),
    codeBorder: const Color(0xFF2B2F38),
    quoteBar: const Color(0xFF3A3E48),
    quoteText: const Color(0xFFA9A69F),
    rule: const Color(0xFF2B2F38),
    tableHeader: const Color(0xFF232630),
    highlightTheme: PreConfig.darkConfig.theme,
  );

  static ReaderPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// Body text size in logical pixels before the user's font-scale multiplier.
const double kBodyFontSize = 17.0;
const double kBodyLineHeight = 1.6;

/// The widest the reading column is allowed to become.
///
/// The reader column grows with the window and then stops here, so a wide
/// desktop monitor is used properly without stretching prose across its full
/// width. A starting value chosen to be close to the measure a code editor
/// gives; it is a tuning knob, not a product constant - lower it if lines feel
/// too long.
const double kMaxProseWidth = 1120.0;

double _readerSidePadding(double viewportWidth) =>
    viewportWidth < 600 ? 20.0 : 32.0;

/// Width of the reading column for a given viewport width.
///
/// Narrow viewports use everything available minus padding, so phone layout is
/// unchanged; wider ones keep growing until [kMaxProseWidth].
double readerContentWidth(double viewportWidth) {
  final side = _readerSidePadding(viewportWidth);
  return math.max(0, math.min(viewportWidth - 2 * side, kMaxProseWidth));
}

/// Horizontal padding that produces [readerContentWidth], centred.
double readerHorizontalPadding(double viewportWidth) {
  final side = _readerSidePadding(viewportWidth);
  final content = readerContentWidth(viewportWidth);
  return math.max(side, (viewportWidth - content) / 2);
}

const String kBodyFont = 'Roboto';
const String kCodeFont = 'CascadiaMono';

ThemeData buildAppTheme(ReaderPalette palette) {
  final scheme = ColorScheme.fromSeed(
    seedColor: palette.link,
    brightness: palette.isDark ? Brightness.dark : Brightness.light,
    surface: palette.background,
  );

  return ThemeData(
    useMaterial3: true,
    fontFamily: kBodyFont,
    brightness: palette.isDark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.background,
    canvasColor: palette.background,
    dividerColor: palette.rule,
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.background,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: palette.isDark
          ? palette.surface
          : const Color(0xFF2B2A27),
      contentTextStyle: TextStyle(
        color: palette.isDark ? palette.text : Colors.white,
        fontFamily: kBodyFont,
      ),
    ),
  );
}

/// Builds the renderer configuration for the current palette and preferences.
///
/// Everything the renderer might otherwise do over the network is overridden
/// here: images become local placeholders, and links are handed to a callback
/// rather than opened by the package.
MarkdownConfig buildMarkdownConfig({
  required ReaderPalette palette,
  required bool wrapCode,
  required void Function(String url) onLinkTap,
}) {
  final body = TextStyle(
    fontSize: kBodyFontSize,
    height: kBodyLineHeight,
    color: palette.text,
  );

  HeadingDivider divider() => HeadingDivider(color: palette.rule, height: 1);

  return MarkdownConfig(
    configs: [
      _HeadingConfig(
        tag: 'h1',
        style: TextStyle(
          fontSize: 28,
          height: 1.25,
          fontWeight: FontWeight.w700,
          color: palette.text,
        ),
        padding: const EdgeInsets.only(top: 24, bottom: 6),
        divider: divider(),
      ),
      _HeadingConfig(
        tag: 'h2',
        style: TextStyle(
          fontSize: 23,
          height: 1.3,
          fontWeight: FontWeight.w700,
          color: palette.text,
        ),
        padding: const EdgeInsets.only(top: 22, bottom: 4),
        divider: divider(),
      ),
      _HeadingConfig(
        tag: 'h3',
        style: TextStyle(
          fontSize: 20,
          height: 1.35,
          fontWeight: FontWeight.w700,
          color: palette.text,
        ),
        padding: const EdgeInsets.only(top: 18, bottom: 2),
      ),
      _HeadingConfig(
        tag: 'h4',
        style: TextStyle(
          fontSize: 17.5,
          height: 1.4,
          fontWeight: FontWeight.w700,
          color: palette.text,
        ),
        padding: const EdgeInsets.only(top: 14, bottom: 2),
      ),
      _HeadingConfig(
        tag: 'h5',
        style: TextStyle(
          fontSize: 16,
          height: 1.4,
          fontWeight: FontWeight.w700,
          color: palette.muted,
        ),
        padding: const EdgeInsets.only(top: 12, bottom: 2),
      ),
      _HeadingConfig(
        tag: 'h6',
        style: TextStyle(
          fontSize: 15,
          height: 1.4,
          fontWeight: FontWeight.w700,
          color: palette.muted,
        ),
        padding: const EdgeInsets.only(top: 10, bottom: 2),
      ),
      PConfig(textStyle: body),
      LinkConfig(
        style: TextStyle(
          fontSize: kBodyFontSize,
          height: kBodyLineHeight,
          color: palette.link,
          decoration: TextDecoration.underline,
          decorationColor: palette.link.withValues(alpha: 0.5),
        ),
        onTap: onLinkTap,
      ),
      // Inline code. backgroundColor gives a tight highlight with no padding,
      // which is the best available option for an inline span.
      CodeConfig(
        style: TextStyle(
          fontFamily: kCodeFont,
          fontSize: kBodyFontSize - 2,
          color: palette.isDark
              ? const Color(0xFFE6C07B)
              : const Color(0xFFB3261E),
          backgroundColor: palette.codeBackground,
        ),
      ),
      // Fenced code. `builder` replaces the package's block entirely so that
      // wrapping, the highlight guard and the copy action live in one widget.
      PreConfig(
        builder: (code, language) => CodeBlock(
          code: code,
          language: language,
          palette: palette,
          wrap: wrapCode,
        ),
      ),
      BlockquoteConfig(
        sideColor: palette.quoteBar,
        textColor: palette.quoteText,
        sideWith: 3,
        padding: const EdgeInsets.fromLTRB(14, 2, 0, 2),
        margin: const EdgeInsets.symmetric(vertical: 10),
      ),
      // 32 is too much indent on a 390pt screen once lists nest three deep.
      const ListConfig(marginLeft: 22, marginBottom: 6),
      TableConfig(
        wrapper: (table) => TableBlock(table: table, palette: palette),
        headerRowDecoration: BoxDecoration(color: palette.tableHeader),
        border: TableBorder.all(color: palette.codeBorder, width: 1),
        headerStyle: TextStyle(
          fontSize: kBodyFontSize - 2,
          height: 1.35,
          fontWeight: FontWeight.w700,
          color: palette.text,
        ),
        bodyStyle: TextStyle(
          fontSize: kBodyFontSize - 2,
          height: 1.35,
          color: palette.text,
        ),
        headPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        bodyPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      ),
      HrConfig(color: palette.rule, height: 1),
      // Remote images are never fetched. See RemoteImagePlaceholder.
      ImgConfig(
        builder: (url, attributes) => RemoteImagePlaceholder(
          url: url,
          alt: attributes['alt'] ?? '',
          palette: palette,
          onOpen: onLinkTap,
        ),
      ),
      CheckBoxConfig(
        builder: (checked) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Icon(
            checked
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded,
            size: kBodyFontSize + 2,
            color: checked ? palette.link : palette.muted,
          ),
        ),
      ),
    ],
  );
}

/// The package's H1Config..H6Config hard-code their colours and divider, so the
/// app supplies its own. Subclassing [HeadingConfig] directly is the pattern
/// markdown_widget itself uses for the TOC.
class _HeadingConfig extends HeadingConfig {
  _HeadingConfig({
    required this.tag,
    required this.style,
    required this.padding,
    this.divider,
  });

  @override
  final String tag;
  @override
  final TextStyle style;
  @override
  final EdgeInsets padding;
  @override
  final HeadingDivider? divider;
}
