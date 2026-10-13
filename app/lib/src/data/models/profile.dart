/// Rich profile payloads returned by the backend profile actions
/// (users.account_get, bots.bot_profile, spaces.space_profile,
/// spaces.room_profile). These back the entity profile screens.
library;

import 'post.dart';

class UserProfile {
  const UserProfile({
    required this.id,
    required this.handle,
    this.kind = 'user',
    this.status = 'active',
    this.displayName = '',
    this.bio = '',
    this.followers = 0,
    this.following = 0,
    this.amFollowing = false,
    this.posts = const [],
  });

  final String id;
  final String handle;
  final String kind;
  final String status;
  final String displayName;
  final String bio;
  final int followers;
  final int following;
  final bool amFollowing;
  final List<SocialPost> posts;

  String get name => displayName.isEmpty ? handle : displayName;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'];
    final p = profile is Map<String, dynamic> ? profile : <String, dynamic>{};
    return UserProfile(
      id: json['id'] as String? ?? '',
      handle: json['handle'] as String? ?? '',
      kind: json['kind'] as String? ?? 'user',
      status: json['status'] as String? ?? 'active',
      displayName: p['display_name'] as String? ?? '',
      bio: p['bio'] as String? ?? '',
      followers: (json['followers'] as num?)?.toInt() ?? 0,
      following: (json['following'] as num?)?.toInt() ?? 0,
      amFollowing: json['am_following'] as bool? ?? false,
    );
  }
}

class BotProfile {
  const BotProfile({
    required this.id,
    required this.name,
    this.kind = '',
    this.vmType = '',
    this.status = '',
    this.imageRef = '',
    this.ownerId = '',
    this.ownerHandle = '',
    this.description = '',
    this.resources = const {},
    this.cost = const {},
    this.usage = const {},
    this.entities = const [],
    this.hasFrontend = false,
    this.listing = const {},
  });

  final String id;
  final String name;
  final String kind;
  final String vmType;
  final String status;
  final String imageRef;
  final String ownerId;
  final String ownerHandle;
  final String description;
  final Map<String, dynamic> resources;
  final Map<String, dynamic> cost;
  final Map<String, dynamic> usage;
  final List<String> entities;
  final bool hasFrontend;
  final Map<String, dynamic> listing;

  int get installs => (listing['installs'] as num?)?.toInt() ?? 0;
  int get price => (listing['price'] as num?)?.toInt() ?? 0;
  int get uptimeSec => (usage['uptime_sec'] as num?)?.toInt() ?? 0;
  int get tokens => (usage['tokens'] as num?)?.toInt() ?? 0;

  factory BotProfile.fromJson(Map<String, dynamic> json) => BotProfile(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        vmType: json['vm_type'] as String? ?? '',
        status: json['status'] as String? ?? '',
        imageRef: json['image_ref'] as String? ?? '',
        ownerId: json['owner_id'] as String? ?? '',
        ownerHandle: json['owner_handle'] as String? ?? '',
        description: json['description'] as String? ?? '',
        resources:
            (json['resources'] as Map?)?.cast<String, dynamic>() ?? const {},
        cost: (json['cost'] as Map?)?.cast<String, dynamic>() ?? const {},
        usage: (json['usage'] as Map?)?.cast<String, dynamic>() ?? const {},
        entities: (json['entities'] as List?)?.whereType<String>().toList() ??
            const [],
        hasFrontend: json['has_frontend'] as bool? ?? false,
        listing: (json['listing'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

class SpaceProfile {
  const SpaceProfile({
    required this.id,
    required this.name,
    this.description = '',
    this.public = false,
    this.home = false,
    this.ownerId = '',
    this.ownerHandle = '',
    this.memberCount = 0,
    this.agentCount = 0,
    this.roomCount = 0,
    this.rooms = const [],
    this.postCount = 0,
    this.fileCount = 0,
    this.amMember = false,
    this.metadata = const {},
  });

  final String id;
  final String name;
  final String description;
  final bool public;
  final bool home;
  final String ownerId;
  final String ownerHandle;
  final int memberCount;
  final int agentCount;
  final int roomCount;
  final List<String> rooms;
  final int postCount;
  final int fileCount;
  final bool amMember;
  final Map<String, dynamic> metadata;

  factory SpaceProfile.fromJson(Map<String, dynamic> json) => SpaceProfile(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        public: json['public'] as bool? ?? false,
        home: json['home'] as bool? ?? false,
        ownerId: json['owner_id'] as String? ?? '',
        ownerHandle: json['owner_handle'] as String? ?? '',
        memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
        agentCount: (json['agent_count'] as num?)?.toInt() ?? 0,
        roomCount: (json['room_count'] as num?)?.toInt() ?? 0,
        rooms:
            (json['rooms'] as List?)?.whereType<String>().toList() ?? const [],
        postCount: (json['post_count'] as num?)?.toInt() ?? 0,
        fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
        amMember: json['am_member'] as bool? ?? false,
        metadata:
            (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

class RoomProfile {
  const RoomProfile({
    required this.id,
    required this.name,
    this.topic = '',
    this.spaceId = '',
    this.spaceName = '',
    this.memberCount = 0,
    this.agentCount = 0,
    this.messageCount = 0,
    this.fileCount = 0,
    this.amMember = false,
    this.recentMessages = const [],
  });

  final String id;
  final String name;
  final String topic;
  final String spaceId;
  final String spaceName;
  final int memberCount;
  final int agentCount;
  final int messageCount;
  final int fileCount;
  final bool amMember;
  final List<Map<String, dynamic>> recentMessages;

  factory RoomProfile.fromJson(Map<String, dynamic> json) => RoomProfile(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        topic: json['topic'] as String? ?? '',
        spaceId: json['space_id'] as String? ?? '',
        spaceName: json['space_name'] as String? ?? '',
        memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
        agentCount: (json['agent_count'] as num?)?.toInt() ?? 0,
        messageCount: (json['message_count'] as num?)?.toInt() ?? 0,
        fileCount: (json['file_count'] as num?)?.toInt() ?? 0,
        amMember: json['am_member'] as bool? ?? false,
        recentMessages: (json['recent_messages'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .toList() ??
            const [],
      );
}
