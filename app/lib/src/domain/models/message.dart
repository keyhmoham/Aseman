class Message {
  const Message(
      {required this.author,
      required this.body,
      required this.sentAt,
      this.isAgent = false});
  final String author;
  final String body;
  final String sentAt;
  final bool isAgent;
}
