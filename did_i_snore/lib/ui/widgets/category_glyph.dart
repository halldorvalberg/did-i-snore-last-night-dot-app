/// Category glyph — the soft rounded icon tile that fronts every event.
///
/// Ported from `components.jsx` `CatGlyph`. Color comes from
/// [CategoryStyle.of] when [useColor] is true; otherwise the neutral
/// grey treatment (category-colors-off).
library;

import 'package:flutter/material.dart';

import '../theme/category_style.dart';

class CategoryGlyph extends StatelessWidget {
  const CategoryGlyph({
    super.key,
    required this.label,
    this.size = 40,
    this.useColor = true,
  });

  final String? label;
  final double size;
  final bool useColor;

  @override
  Widget build(BuildContext context) {
    final style = CategoryStyle.of(label);
    final bg = useColor ? style.tileBg : CategoryStyle.neutralBg;
    final tint = useColor ? style.tint : CategoryStyle.neutralTint;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: const Color(0x0FFFFFFF)),
      ),
      child: Icon(style.icon, size: size * 0.52, color: tint),
    );
  }
}
