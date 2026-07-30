# TODO

- [ ] Add scroll-aware back-buffer updates after the retained Direct2D renderer
  is established: detect terminal scroll damage, shift reusable rendered pixels
  within the affected region, and redraw only newly exposed rows. Handle
  multiple scroll operations in one terminal batch, partial scroll regions,
  cursor and selection overlays, resize/DPI invalidation, and cases where a
  dirty-row redraw is cheaper than copying. Benchmark the result before making
  it the default path.
