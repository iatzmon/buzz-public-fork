part of 'channel_detail_page_test.dart';

/// Community owners/admins get the existing "Delete message" action on other
/// members' stream messages and thread replies, sent as a NIP-29 kind:9005
/// moderator delete. Editing stays author/agent-owner only. Self-authored
/// deletes keep NIP-09 kind:5; own-agent deletes use kind:5 unless the viewer
/// also moderates, in which case they use kind:9005.
void moderatorDeleteTests() {
  group('moderator message delete', () {
    const threadRootId = 'moderated-root';
    final root = _textMsg(
      id: threadRootId,
      pubkey: 'alice',
      content: 'Thread root',
    );
    final reply = _textMsg(
      id: 'bob-reply',
      pubkey: 'bob',
      content: 'Bob reply',
      createdAt: 1001,
      extraTags: [
        ['e', threadRootId, '', 'reply'],
      ],
    );

    Future<void> openActions(WidgetTester tester, String rowKey) async {
      await tester.longPress(find.byKey(ValueKey(rowKey)));
      await tester.pumpAndSettle();
    }

    // The popover is presented one at a time app-wide, so tests that only
    // inspect it must dismiss it before the next test opens another.
    Future<void> dismissActions(WidgetTester tester) async {
      Navigator.of(
        tester.element(find.byKey(const ValueKey('message-action-surface'))),
      ).pop();
      await tester.pumpAndSettle();
    }

    Future<void> confirmDelete(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('message-action-delete')));
      await tester.pumpAndSettle();
      expect(find.text('This cannot be undone.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
    }

    for (final author in ['alice', 'agent']) {
      testWidgets('community admin deletes $author\'s stream message with '
          'kind 9005 and never sees Edit', (tester) async {
        final relay = RecordingSignedEventRelay();
        await tester.pumpWidget(
          _buildTestable(
            messages: [
              _textMsg(id: 'target', pubkey: author, content: 'Target'),
            ],
            users: const {
              'agent': UserProfile(
                pubkey: 'agent',
                displayName: 'Agent',
                ownerPubkey: 'someone-else',
              ),
            },
            communityRole: CommunityMemberRole.admin,
            createChannelActions: recordingChannelActions(relay),
          ),
        );
        await tester.pumpAndSettle();

        await openActions(tester, 'message-row-target');
        expect(
          find.byKey(const ValueKey('message-action-delete')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('message-action-edit')), findsNothing);

        await confirmDelete(tester);

        expect(relay.submissions, hasLength(1));
        expect(relay.submissions.single.kind, EventKind.nip29DeleteEvent);
        expect(relay.submissions.single.tags, [
          ['h', _channelId],
          ['e', 'target'],
        ]);
      });
    }

    for (final role in [CommunityMemberRole.member, null]) {
      testWidgets('$role sees neither Edit nor Delete on another member\'s '
          'stream message', (tester) async {
        await tester.pumpWidget(
          _buildTestable(
            messages: [
              _textMsg(id: 'target', pubkey: 'alice', content: 'Target'),
            ],
            members: [
              ChannelMember(
                pubkey: 'self',
                role: 'member',
                joinedAt: DateTime(2025),
              ),
            ],
            communityRole: role,
          ),
        );
        await tester.pumpAndSettle();

        await openActions(tester, 'message-row-target');
        expect(
          find.byKey(const ValueKey('message-action-copyText')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('message-action-delete')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('message-action-edit')), findsNothing);
        await dismissActions(tester);
      });
    }

    testWidgets('channel admin deletes another member\'s stream message with '
        'kind 9005 and never sees Edit', (tester) async {
      final relay = RecordingSignedEventRelay();
      await tester.pumpWidget(
        _buildTestable(
          messages: [
            _textMsg(id: 'target', pubkey: 'alice', content: 'Target'),
          ],
          members: [
            ChannelMember(
              pubkey: 'self',
              role: 'admin',
              joinedAt: DateTime(2025),
            ),
            ChannelMember(
              pubkey: 'alice',
              role: 'member',
              joinedAt: DateTime(2025),
            ),
          ],
          communityRole: CommunityMemberRole.member,
          createChannelActions: recordingChannelActions(relay),
        ),
      );
      await tester.pumpAndSettle();

      await openActions(tester, 'message-row-target');
      expect(find.byKey(const ValueKey('message-action-edit')), findsNothing);

      await confirmDelete(tester);

      expect(relay.submissions.single.kind, EventKind.nip29DeleteEvent);
    });

    const ownAgentProfile = UserProfile(
      pubkey: 'my-agent',
      displayName: 'My Agent',
      ownerPubkey: 'self',
    );

    for (final (role, channelRole, expectedKind) in [
      (CommunityMemberRole.admin, 'member', EventKind.nip29DeleteEvent),
      (CommunityMemberRole.member, 'owner', EventKind.nip29DeleteEvent),
      (CommunityMemberRole.member, 'member', EventKind.deletion),
    ]) {
      testWidgets('own agent\'s stream message with community $role / channel '
          '$channelRole keeps Edit and deletes with kind $expectedKind', (
        tester,
      ) async {
        final relay = RecordingSignedEventRelay();
        await tester.pumpWidget(
          _buildTestable(
            messages: [
              _textMsg(id: 'agent-msg', pubkey: 'my-agent', content: 'Hi'),
            ],
            users: const {'my-agent': ownAgentProfile},
            members: [
              ChannelMember(
                pubkey: 'self',
                role: channelRole,
                joinedAt: DateTime(2025),
              ),
            ],
            communityRole: role,
            createChannelActions: recordingChannelActions(relay),
          ),
        );
        await tester.pumpAndSettle();

        await openActions(tester, 'message-row-agent-msg');
        expect(
          find.byKey(const ValueKey('message-action-edit')),
          findsOneWidget,
        );

        await confirmDelete(tester);

        expect(relay.submissions.single.kind, expectedKind);
        expect(relay.submissions.single.tags, [
          ['h', _channelId],
          ['e', 'agent-msg'],
        ]);
      });
    }

    testWidgets('community admin deletes their own agent\'s thread reply with '
        'kind 9005 and keeps Edit', (tester) async {
      final relay = RecordingSignedEventRelay();
      final agentReply = _textMsg(
        id: 'agent-reply',
        pubkey: 'my-agent',
        content: 'Agent reply',
        createdAt: 1001,
        extraTags: [
          ['e', threadRootId, '', 'reply'],
        ],
      );
      await tester.pumpWidget(
        _buildTestable(
          messages: [root],
          users: const {'my-agent': ownAgentProfile},
          threadReplies: {
            threadRootId: [agentReply],
          },
          communityRole: CommunityMemberRole.admin,
          createChannelActions: recordingChannelActions(relay),
        ),
      );
      await tester.pumpAndSettle();
      // Push the thread with the resolved viewer pubkey (as the app does once
      // the signing identity is known) so the agent-owner rule applies.
      final head = formatTimeline([root]).single;
      Navigator.of(tester.element(find.byType(ChannelDetailPage))).push(
        MaterialPageRoute<void>(
          builder: (_) => ThreadDetailPage(
            threadHead: head,
            allMessages: [head],
            channelId: _channelId,
            currentPubkey: 'self',
            isMember: true,
            isArchived: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await openActions(tester, 'thread-message-row-agent-reply');
      expect(find.byKey(const ValueKey('message-action-edit')), findsOneWidget);

      await confirmDelete(tester);

      expect(relay.submissions.single.kind, EventKind.nip29DeleteEvent);
    });

    testWidgets('community admin deleting their own message keeps Edit and '
        'the kind 5 author path', (tester) async {
      final relay = RecordingSignedEventRelay();
      await tester.pumpWidget(
        _buildTestable(
          messages: [_textMsg(id: 'mine', pubkey: 'self', content: 'Mine')],
          communityRole: CommunityMemberRole.owner,
          createChannelActions: recordingChannelActions(relay),
        ),
      );
      await tester.pumpAndSettle();

      await openActions(tester, 'message-row-mine');
      expect(find.byKey(const ValueKey('message-action-edit')), findsOneWidget);

      await confirmDelete(tester);

      expect(relay.submissions.single.kind, EventKind.deletion);
      expect(relay.submissions.single.tags, [
        ['h', _channelId],
        ['e', 'mine'],
      ]);
    });

    testWidgets('a rejected moderator delete surfaces in a SnackBar', (
      tester,
    ) async {
      final relay = RecordingSignedEventRelay(error: Exception('rejected'));
      await tester.pumpWidget(
        _buildTestable(
          messages: [
            _textMsg(id: 'target', pubkey: 'alice', content: 'Target'),
          ],
          communityRole: CommunityMemberRole.admin,
          createChannelActions: recordingChannelActions(relay),
        ),
      );
      await tester.pumpAndSettle();

      await openActions(tester, 'message-row-target');
      await confirmDelete(tester);

      expect(relay.submissions.single.kind, EventKind.nip29DeleteEvent);
      expect(
        find.text('Failed to delete message: Exception: rejected'),
        findsOneWidget,
      );
    });

    testWidgets('community admin deletes another member\'s thread reply with '
        'kind 9005 and never sees Edit', (tester) async {
      final relay = RecordingSignedEventRelay();
      await tester.pumpWidget(
        _buildTestable(
          messages: [root],
          threadReplies: {
            threadRootId: [reply],
          },
          initialThreadRootId: threadRootId,
          communityRole: CommunityMemberRole.admin,
          createChannelActions: recordingChannelActions(relay),
        ),
      );
      await tester.pumpAndSettle();

      await openActions(tester, 'thread-message-row-bob-reply');
      expect(find.byKey(const ValueKey('message-action-edit')), findsNothing);

      await confirmDelete(tester);

      expect(relay.submissions.single.kind, EventKind.nip29DeleteEvent);
      expect(relay.submissions.single.tags, [
        ['h', _channelId],
        ['e', 'bob-reply'],
      ]);
    });

    testWidgets('plain member cannot delete another member\'s thread reply', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildTestable(
          messages: [root],
          threadReplies: {
            threadRootId: [reply],
          },
          initialThreadRootId: threadRootId,
          communityRole: CommunityMemberRole.member,
        ),
      );
      await tester.pumpAndSettle();

      await openActions(tester, 'thread-message-row-bob-reply');
      expect(
        find.byKey(const ValueKey('message-action-copyText')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('message-action-delete')), findsNothing);
      expect(find.byKey(const ValueKey('message-action-edit')), findsNothing);
      await dismissActions(tester);
    });
  });
}
