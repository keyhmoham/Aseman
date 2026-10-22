import 'package:flutter/material.dart';

import 'skeleton.dart';

/// A [ListView] that loads more items when the user scrolls near the end,
/// showing [loadingItem] at the bottom while the next page is fetched.
class PagedListView<T> extends StatelessWidget {
  const PagedListView({
    super.key,
    required this.items,
    required this.hasMore,
    required this.onLoadMore,
    required this.itemBuilder,
    this.controller,
    this.padding,
    this.separatorBuilder,
    this.empty,
    this.loading = false,
    this.loadingItem = const SkeletonListTile(),
    this.threshold = 300,
    this.physics,
  });

  final List<T> items;
  final bool hasMore;
  final VoidCallback onLoadMore;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;
  final Widget Function(BuildContext context, int index)? separatorBuilder;
  final Widget? empty;
  final bool loading;

  /// A skeleton of one item, shown while more load.
  final Widget loadingItem;
  final double threshold;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && !loading) {
      return empty ?? const SizedBox.shrink();
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (hasMore &&
            !loading &&
            notification.metrics.extentAfter < threshold) {
          onLoadMore();
        }
        return false;
      },
      child: ListView.separated(
        controller: controller,
        padding: padding,
        physics: physics,
        itemCount: items.length + (hasMore || loading ? 1 : 0),
        separatorBuilder:
            separatorBuilder ?? (_, __) => const SizedBox.shrink(),
        itemBuilder: (context, index) {
          if (index >= items.length) {
            return loadingItem;
          }
          return itemBuilder(context, items[index]);
        },
      ),
    );
  }
}
