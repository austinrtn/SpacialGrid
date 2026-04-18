● In update(), right before workers are dispatched. The generation logic is straightforward — for each
  kernel, split the A-side entity count into chunks:

  for each of the 6 kernels:
      if A-side storage is empty, skip
      chunk_size = ceil(a_side_count / thread_count)
      push work items: [0..chunk], [chunk..2*chunk], ... until a_side_count

  So with 4 threads and 1000 circles:
  - cc kernel → 4 items: [0-250), [250-500), [500-750), [750-1000)
  - cr kernel → 4 items: same ranges, but workers query rects as inner loop
  - cp kernel → 4 items: same, workers query points as inner
  - rr kernel → however many rects ÷ 4
  - etc.

  Up to 6 × thread_count work items total, all pushed into the shared queue before workers start. Workers
  pull dynamically — if circle-circle finishes fast because there are few circles, those workers
  immediately grab rect-rect items instead of sitting idle. That self-balancing is the main advantage over
   static assignment.

  One edge case worth thinking about: what if one shape type dominates — say 10,000 rects and 3 circles?
  The cc kernel generates almost no work, cr generates 3 work items (one per circle chunk), rr generates 4
   large items. Workers naturally pile onto rr since it has the most items. No special handling needed —
  the queue handles it.

  Does the current WorkQueue already work as a shared pull queue, or is it more like static assignment per
   worker?

❯ So is it one worker per kernel then?

● No — workers are agnostic to kernel type. Any worker can pull any work item from the queue regardless of
   which kernel it is. That's the point of tagging the work item with the kernel type rather than
  assigning kernels to specific workers.

  So with 4 workers and say 20 work items across 6 kernels, each worker just loops:

  while queue has items:
      item = queue.pop()
      switch item.kernel:
          .cc => findCircleCircle(item.start, item.end)
          .cr => findCircleRect(item.start, item.end)
          ...

  Workers don't know or care which kernel they'll get next. The queue empties as fast as all 4 workers can
   drain it together. This is generally called a thread pool pattern — fixed pool of workers, dynamic pool
   of tasks.

  The alternative (one worker per kernel) would mean 6 threads minimum, threads sit idle when their kernel
   has no work, and you get no parallelism within a kernel. Much worse.
