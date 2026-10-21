/// One entry of the in-app notification inbox (users.notifications_list):
/// something the user was told about, like a message in a space they were
/// not looking at or an invitation.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.kind,
    required this.createdAt,
    this.space = '',
    this.room = '',
    this.read = false,
  });

  final String id;
  final String title;
  final String body;

  /// What happened: "message" or "invite".
  final String kind;

  /// The space (and room) it happened in, if any.
  final String space;
  final String room;
  final bool read;
  final DateTime createdAt;

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      AppNotification(
        id: '${json['id'] ?? ''}',
        title: '${json['title'] ?? ''}',
        body: '${json['body'] ?? ''}',
        kind: '${json['kind'] ?? ''}',
        space: '${json['space'] ?? ''}',
        room: '${json['room'] ?? ''}',
        read: json['read'] == true,
        createdAt: DateTime.tryParse('${json['created_at'] ?? ''}')?.toLocal() ??
            DateTime.now(),
      );
}
