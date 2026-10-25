import 'package:flutter/material.dart';

import '../app/theme.dart';

export 'common.dart' show formatLongDate, formatShortDate;

/// Standard page layout: large title, optional subtitle, roomy content.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Less padding, and the trailing controls move under the title, on
    // phone-width screens.
    final narrow = MediaQuery.sizeOf(context).width < 640;
    final pad = narrow ? Space.lg : Space.page;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: Space.xs),
          Text(
            subtitle!,
            style: TextStyle(fontSize: 14, color: AppColors.textMuted),
          ),
        ],
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, narrow ? Space.xl : 40, pad, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (narrow) ...[
            heading,
            if (trailing != null) ...[
              const SizedBox(height: Space.md),
              trailing!,
            ],
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: heading),
                ?trailing,
              ],
            ),
          SizedBox(height: narrow ? Space.xl : Space.xxl),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A bordered card with a small header row, as on the prototype dashboard.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.action,
    required this.child,
  });

  final String title;
  final Widget? action;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Space.xl),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: Space.lg),
          child,
        ],
      ),
    );
  }
}

/// Clearly marks a feature that is planned but not built yet.
class ComingSoon extends StatelessWidget {
  const ComingSoon({
    super.key,
    required this.milestone,
    required this.description,
    this.icon = Icons.schedule,
  });

  final int milestone;
  final String description;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.textFaint),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Planned for Milestone $milestone. ',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                  TextSpan(text: description),
                ],
              ),
              style: TextStyle(
                fontSize: 13,
                color: AppColors.textFaint,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
