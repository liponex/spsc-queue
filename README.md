# SPSC Queue

Zig implementation of a lock-free single-producer, single-consumer queue, based on [the CppCon talk by Charles Frasch (YouTube)](https://www.youtube.com/watch?v=K3P_Lmq6pw0).

---

Original project by [@cancername](https://codeberg.org/cancername): [link](https://codeberg.org/zig-multimedia/spsc-queue)

---

# How to use it

<details> <summary>Fetch dependency</summary>

  To fetch master branch use this command:
  ```bash
  zig fetch --save=spsc_queue git+https://github.com/liponex/spsc-queue.git#master
  ```
</details>

<details> <summary>build.zig</summary>

  Add dependency:
  ```zig
  const spsc_queue = b.dependency("spsc_queue", .{
      .target = target,
      .optimize = optimize,
  });
  ```
  
  Add import and install artifact
  ```zig
  compile.root_module.addImport("spsc_queue", spsc_queue.module("queue"));
  const spsc_queue_artifact = b.addStaticLibrary(.{
      .name = "spsc_queue",
      .root_source_file = spsc_queue.path("src/main.zig"),
      .target = target,
      .optimize = optimize,
  });
  
  b.installArtifact(spsc_queue_artifact);
  ```
  Where `compile` might be lib or exe
  
  If you has more compilation targets (e.g. tests), you can add:
  ```zig
  unit_tests.root_module.addImport("spsc_queue", spsc_queue.module("queue"));
  ```
  Where `unit_tests` is a value of `b.addTest`
</details>

<details> <summary>Usage example</summary>
  
  Import dependency:
  ```zig
  const std = @import("std");
  const spsc = @import("spsc_queue");
  ```

  Producer thread function
  ```zig
  fn producer(queue: *spsc.Queue(u8, 8, true)) void {
      for (0..255) |i| {
          queue.push(i);
      }
  }
  ```

  Consumer thread function
  ```zig
  fn consumer(queue: *spsc.Queue(u8, 8, true)) void {
      for (0..255) {
          std.log.info("{d}", .{queue.pop()});
      }
  }
  ```

  Initializing
  ```zig
  pub fn main() !void {
      var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
      defer arena.deinit();
      const allocator = arena.allocator();
      
      var queue = spsc.Queue(u8, 8, true){};
      const producer_thread = try std.Thread.spawn(
          .{.allocator = allocator},
          producer,
          .{ &queue });
      producer_thread.detach();

      const consumer_thread = try std.Thread.spawn(
          .{.allocator = allocator},
          consumer,
          .{ &queue });
      consumer_thread.join();
  }
  ```
</details>
