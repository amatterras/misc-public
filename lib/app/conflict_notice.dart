// A small notice that stays on every page while sync conflicts wait for a
// decision, so they are not only visible in Settings. It disappears when the
// last open conflict is settled; tapping it opens the review window.
import 'package:flutter/material.dart';

import '../features/settings/conflict_review.dart';
import '../phone/phone_profile.dart';
import 'app_state.dart';
import 'theme.dart';

class ConflictNotice extends StatelessWidget {
  const ConflictNotice({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state.workspace.conflicts,
      builder: (context, _) {
        final n = state.openConflictCount;
        if (n == 0) return const SizedBox.shrink();
        return Positioned(
          left: 16,
          // Above the phone's tab bar; on desktop above the page edge.
          bottom: PhoneProfile.active ? 124 : 56,
          child: Material(
            key: const ValueKey('conflict-notice'),
            color: AppColors.cardRaised,
            elevation: 2,
            shape: StadiumBorder(side: BorderSide(color: AppColors.warm)),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => showConflictReview(context, state),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.call_split, size: 16, color: AppColors.warm),
                    const SizedBox(width: 8),
                    Text(
                      n == 1
                          ? '1 sync conflict to review'
                          : '$n sync conflicts to review',
                      style: TextStyle(fontSize: 13, color: AppColors.text),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
