import 'package:flutter/material.dart';

enum AppDestination {
  home('Pulse', Icons.home_rounded),
  chats('Chats', Icons.chat_bubble_rounded),
  room('Rooms & desks', Icons.grid_view_rounded),
  explore('Explore', Icons.explore_rounded),
  agents('Agents', Icons.smart_toy_rounded),
  wallet('Wallet', Icons.account_balance_wallet_rounded),
  admin('Admin console', Icons.admin_panel_settings_rounded);

  const AppDestination(this.label, this.icon);
  final String label;
  final IconData icon;
}
