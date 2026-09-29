part of '../notes_page.dart';

/// A profile name, or a short key while the profile loads.
String Function(String) _authorLabel(WidgetRef ref) {
  final profiles = ref.watch(userCacheProvider);
  return (key) =>
      profiles[key]?.label ??
      (key.length <= 8 ? key : '${key.substring(0, 8)}…');
}

class _AuthorAvatar extends ConsumerWidget {
  const _AuthorAvatar({required this.pubkey, this.radius = 16});

  final String pubkey;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(
      userCacheProvider.select((cache) => cache[pubkey]),
    );
    return AvatarImage(
      imageUrl: profile?.avatarUrl,
      radius: radius,
      isAgent: profile?.ownerPubkey != null,
      backgroundColor: context.colors.primaryContainer,
      fallback: Text(
        (profile ?? UserProfile(pubkey: pubkey)).initial,
        style: TextStyle(
          fontSize: radius * 0.85,
          fontWeight: FontWeight.w600,
          color: context.colors.onPrimaryContainer,
        ),
      ),
    );
  }
}
