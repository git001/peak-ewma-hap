package at.none.work;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicReferenceArray;

import at.none.work.proto.WorkGrpc;
import at.none.work.proto.WorkReply;
import at.none.work.proto.WorkRequest;
import io.grpc.stub.StreamObserver;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.grpc.server.service.GrpcService;

/*
 * Each call burns cpu_us of CPU, allocates alloc_kb of short-lived garbage,
 * and replaces one entry of a cache of retain-mb. The replaced entries have
 * survived long enough to be promoted, so the old generation fills up and
 * the collector has real work: the pauses come from the JVM itself, not
 * from a sleep. All services run with the same settings.
 */
@GrpcService
public class WorkService extends WorkGrpc.WorkImplBase {

	private final String server;
	private final AtomicReferenceArray<byte[]> cache;
	private final int slotBytes;

	// keeps the garbage reachable until written, so it is not optimized away
	private volatile byte[] sink;

	public WorkService(@Value("${work.retain-mb:100}") int retainMb,
			@Value("${work.slot-kb:64}") int slotKb) {
		this.server = hostname();
		this.slotBytes = slotKb * 1024;
		this.cache = new AtomicReferenceArray<>(Math.max(1, retainMb * 1024 / slotKb));
		for (int i = 0; i < this.cache.length(); i++)
			this.cache.set(i, new byte[this.slotBytes]);
	}

	@Override
	public void run(WorkRequest req, StreamObserver<WorkReply> out) {
		long start = System.nanoTime();

		burn(req.getCpuUs());
		if (req.getAllocKb() > 0) {
			byte[] garbage = new byte[req.getAllocKb() * 1024];
			garbage[garbage.length - 1] = 1;
			this.sink = garbage;
		}
		ThreadLocalRandom rnd = ThreadLocalRandom.current();
		this.cache.set(rnd.nextInt(this.cache.length()), new byte[this.slotBytes]);

		out.onNext(WorkReply.newBuilder()
				.setServer(this.server)
				.setServerUs((System.nanoTime() - start) / 1000)
				.build());
		out.onCompleted();
	}

	private static void burn(int us) {
		long end = System.nanoTime() + us * 1000L;
		long x = 0;
		while (System.nanoTime() < end)
			for (int i = 0; i < 100; i++)
				x = x * 6364136223846793005L + 1442695040888963407L;
		if (x == 42)
			System.out.print("");
	}

	private static String hostname() {
		try {
			return InetAddress.getLocalHost().getHostName();
		}
		catch (UnknownHostException e) {
			return "unknown";
		}
	}

}
