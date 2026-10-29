import XCTest
@testable import DevmachineCore

final class PrismaSchemaParserTests: XCTestCase {
    private let schema = """
    datasource db {
      provider = "postgresql"
      url      = env("DATABASE_URL")
    }

    /// Someone who can sign in
    model User {
      id        Int       @id @default(autoincrement())
      email     String    @unique
      name      String?
      role      Role      @default(MEMBER)
      posts     Post[]
      profile   Profile?
      teams     Team[]
      createdAt DateTime  @default(now()) // when
    }

    model Profile {
      id     Int    @id @default(autoincrement())
      bio    String @default("a // not a comment")
      user   User   @relation(fields: [userId], references: [id], onDelete: Cascade)
      userId Int    @unique
    }

    model Post {
      id       Int     @id @default(autoincrement())
      title    String  @db.VarChar(255)
      author   User?   @relation(fields: [authorId], references: [id])
      authorId Int?
      tags     String[]
      geo      Unsupported("circle")?
    }

    model Team {
      id      Int    @id
      members User[]
    }

    model Membership {
      teamId Int
      userId Int
      @@id([teamId, userId])
    }

    enum Role {
      MEMBER
      ADMIN
    }
    """

    func testParsesModelsColumnsAndEnums() throws {
        let parsed = PrismaSchemaParser.parse(schema)
        XCTAssertEqual(parsed.dialect, .postgres)
        XCTAssertEqual(parsed.tables.map(\.name), ["User", "Profile", "Post", "Team", "Membership"])
        let user = try XCTUnwrap(parsed.table("User"))
        XCTAssertEqual(user.columns.map(\.name), ["id", "email", "name", "role", "createdAt"])
        XCTAssertEqual(user.comment, "Someone who can sign in")
        XCTAssertTrue(user.column("id")!.isPrimaryKey)
        XCTAssertEqual(user.column("id")!.defaultValue, "autoincrement()")
        XCTAssertTrue(user.column("email")!.isUnique)
        XCTAssertTrue(user.column("name")!.isNullable)
        XCTAssertEqual(user.column("role")!.type, "Role")
        XCTAssertEqual(parsed.enums, [DBEnum(name: "Role", values: ["MEMBER", "ADMIN"])])
        XCTAssertEqual(parsed.table("Profile")?.column("bio")?.defaultValue, "\"a // not a comment\"")
        let post = try XCTUnwrap(parsed.table("Post"))
        XCTAssertTrue(post.column("tags")!.isList)
        XCTAssertEqual(post.column("geo")?.type, "Unsupported(\"circle\")")
        XCTAssertEqual(parsed.table("Membership")?.primaryKey, ["teamId", "userId"])
    }

    func testRelationsAndCardinality() throws {
        let parsed = PrismaSchemaParser.parse(schema)
        let profile = try XCTUnwrap(parsed.relations.first { $0.from == "Profile" })
        XCTAssertEqual(profile.to, "User")
        XCTAssertEqual(profile.fromColumns, ["userId"])
        XCTAssertEqual(profile.toColumns, ["id"])
        XCTAssertEqual(profile.kind, .oneToOne)
        XCTAssertEqual(profile.onDelete, "Cascade")
        let post = try XCTUnwrap(parsed.relations.first { $0.from == "Post" })
        XCTAssertEqual(post.kind, .manyToOne)
        XCTAssertTrue(post.isOptional)
        let manyToMany = parsed.relations.filter { $0.kind == .manyToMany }
        XCTAssertEqual(manyToMany.count, 1)
        XCTAssertEqual(Set([manyToMany[0].from, manyToMany[0].to]), ["User", "Team"])
    }

    func testMongoProviderMakesCollectionsAndEmbeddedTypes() {
        let parsed = PrismaSchemaParser.parse("""
        model Order {
          id      String  @id @default(auto()) @map("_id") @db.ObjectId
          address Address
        }
        type Address {
          street String
          city   String
        }
        datasource db {
          provider = "mongodb"
          url      = env("DATABASE_URL")
        }
        """)
        XCTAssertEqual(parsed.dialect, .mongodb)
        XCTAssertEqual(parsed.table("Order")?.kind, .collection)
        XCTAssertEqual(parsed.table("Address")?.kind, .embedded)
        XCTAssertEqual(parsed.relations, [DBRelation(from: "Order", fromColumns: ["address"], to: "Address", toColumns: [], kind: .embedded)])
    }
}

final class SQLSchemaParserTests: XCTestCase {
    func testCreateTableWithInlineAndTableConstraints() throws {
        let parsed = SQLSchemaParser.parse("""
        -- customers
        CREATE TYPE "Status" AS ENUM ('open', 'paid');
        CREATE TABLE public.customers (
          id serial PRIMARY KEY,
          email varchar(255) NOT NULL UNIQUE,
          meta jsonb DEFAULT '{}'::jsonb
        );
        /* orders */
        CREATE TABLE IF NOT EXISTS "orders" (
          "id" uuid NOT NULL DEFAULT gen_random_uuid(),
          "customer_id" integer REFERENCES customers(id) ON DELETE CASCADE,
          total numeric(10, 2) NOT NULL,
          status "Status" NOT NULL,
          CONSTRAINT orders_pkey PRIMARY KEY (id)
        );
        CREATE TABLE auth.users (id uuid PRIMARY KEY);
        CREATE FUNCTION touch() RETURNS trigger AS $$ BEGIN NEW.x = 1; RETURN NEW; END; $$ LANGUAGE plpgsql;
        INSERT INTO customers (email) VALUES ('alice@example.com');
        """)
        XCTAssertEqual(parsed.dialect, .postgres)
        XCTAssertEqual(parsed.tables.map(\.name), ["customers", "orders", "auth.users"])
        let customers = try XCTUnwrap(parsed.table("customers"))
        XCTAssertEqual(customers.columns.map(\.name), ["id", "email", "meta"])
        XCTAssertTrue(customers.column("id")!.isPrimaryKey)
        XCTAssertEqual(customers.column("id")!.defaultValue, "autoincrement()")
        XCTAssertEqual(customers.column("email")!.type, "varchar(255)")
        XCTAssertFalse(customers.column("email")!.isNullable)
        XCTAssertTrue(customers.column("email")!.isUnique)
        let orders = try XCTUnwrap(parsed.table("orders"))
        XCTAssertEqual(orders.primaryKey, ["id"])
        XCTAssertEqual(orders.column("total")?.type, "numeric(10, 2)")
        XCTAssertEqual(parsed.enums, [DBEnum(name: "Status", values: ["open", "paid"])])
        let relation = try XCTUnwrap(parsed.relations.first)
        XCTAssertEqual(relation.label, "orders.customer_id → customers.id")
        XCTAssertEqual(relation.onDelete, "CASCADE")
        XCTAssertTrue(relation.isOptional)
        XCTAssertEqual(relation.kind, .manyToOne)
    }

    func testMigrationsApplyInOrder() throws {
        let parsed = SQLSchemaParser.parse(files: [
            """
            CREATE TABLE "User" ("id" SERIAL NOT NULL, "name" TEXT, CONSTRAINT "User_pkey" PRIMARY KEY ("id"));
            CREATE TABLE "Post" ("id" SERIAL NOT NULL, "authorId" INTEGER NOT NULL, "draft" BOOLEAN);
            CREATE TABLE "Old" ("id" INTEGER);
            """,
            """
            ALTER TABLE "Post" ADD CONSTRAINT "Post_authorId_fkey" FOREIGN KEY ("authorId") REFERENCES "User"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
            ALTER TABLE "User" ADD COLUMN "email" TEXT NOT NULL;
            CREATE UNIQUE INDEX "User_email_key" ON "User"("email");
            ALTER TABLE "Post" DROP COLUMN "draft";
            ALTER TABLE "User" RENAME COLUMN "name" TO "fullName";
            ALTER TABLE "User" ALTER COLUMN "fullName" SET NOT NULL;
            DROP TABLE "Old";
            """,
            """
            ALTER TABLE "Post" RENAME TO "Article";
            """,
        ])
        XCTAssertEqual(parsed.tables.map(\.name), ["User", "Article"])
        let user = try XCTUnwrap(parsed.table("User"))
        XCTAssertEqual(user.columns.map(\.name), ["id", "fullName", "email"])
        XCTAssertFalse(user.column("fullName")!.isNullable)
        XCTAssertTrue(user.column("email")!.isUnique)
        XCTAssertNil(parsed.table("Article")?.column("draft"))
        XCTAssertEqual(parsed.relations.map(\.label), ["Article.authorId → User.id"])
        XCTAssertEqual(parsed.relations.first?.onDelete, "RESTRICT")
    }

    func testMySQLSpelling() throws {
        let parsed = SQLSchemaParser.parse("""
        CREATE TABLE `teams` (`id` INT NOT NULL AUTO_INCREMENT, PRIMARY KEY (`id`)) ENGINE=InnoDB;
        CREATE TABLE `members` (
          `id` INT NOT NULL AUTO_INCREMENT,
          `team_id` INT NOT NULL,
          PRIMARY KEY (`id`),
          KEY `team_idx` (`team_id`),
          CONSTRAINT `fk_team` FOREIGN KEY (`team_id`) REFERENCES `teams` (`id`)
        );
        ALTER TABLE `members` DROP FOREIGN KEY `fk_team`;
        ALTER TABLE `members` ADD CONSTRAINT `fk_team2` FOREIGN KEY (`team_id`) REFERENCES `teams` (`id`);
        """)
        XCTAssertEqual(parsed.dialect, .mysql)
        XCTAssertEqual(parsed.table("teams")?.column("id")?.defaultValue, "autoincrement()")
        XCTAssertEqual(parsed.relations.map(\.label), ["members.team_id → teams.id"])
    }
}

final class DBMLAndMongooseParserTests: XCTestCase {
    func testDBML() throws {
        let parsed = DBMLParser.parse("""
        Project acme {
          database_type: 'PostgreSQL'
        }
        Table users as U {
          id integer [pk, increment]
          email varchar [unique, not null, note: 'login']
          created_at timestamp [default: `now()`]
        }
        Table posts {
          id integer [pk]
          user_id integer [ref: > users.id]
          title varchar
          indexes {
            (title) [unique]
          }
        }
        Table likes {
          post_id integer
          user_id integer
        }
        Ref: likes.post_id > posts.id
        Ref: likes.user_id > U.id
        Enum status {
          draft
          live [note: 'shown']
        }
        """)
        XCTAssertEqual(parsed.dialect, .postgres)
        XCTAssertEqual(parsed.tables.map(\.name), ["users", "posts", "likes"])
        XCTAssertTrue(parsed.table("users")!.column("id")!.isPrimaryKey)
        XCTAssertEqual(parsed.table("users")?.column("email")?.comment, "login")
        XCTAssertTrue(parsed.table("posts")!.column("title")!.isUnique)
        XCTAssertEqual(Set(parsed.relations.map(\.label)), [
            "posts.user_id → users.id", "likes.post_id → posts.id", "likes.user_id → users.id",
        ])
        XCTAssertEqual(parsed.enums, [DBEnum(name: "status", values: ["draft", "live"])])
    }

    func testMongoose() throws {
        let parsed = MongooseSchemaParser.parse(files: [
            """
            import mongoose, { Schema } from 'mongoose';
            const userSchema = new Schema({
              email: { type: String, required: true, unique: true },
              name: String,
              address: { street: String, city: String },
              friends: [{ type: Schema.Types.ObjectId, ref: 'User' }],
            }, { timestamps: true });
            export default mongoose.model('User', userSchema);
            """,
            """
            const OrderSchema = new mongoose.Schema({
              // the buyer
              user: { type: mongoose.Schema.Types.ObjectId, ref: 'User', required: true },
              items: [String],
            });
            """,
        ])
        XCTAssertEqual(parsed.dialect, .mongodb)
        XCTAssertEqual(parsed.tables.map(\.name), ["User", "User.address", "Order"])
        let user = try XCTUnwrap(parsed.table("User"))
        XCTAssertEqual(user.columns.map(\.name), ["_id", "email", "name", "address", "friends", "createdAt", "updatedAt"])
        XCTAssertFalse(user.column("email")!.isNullable)
        XCTAssertTrue(user.column("email")!.isUnique)
        XCTAssertTrue(user.column("friends")!.isList)
        XCTAssertEqual(user.column("friends")?.type, "ObjectId")
        XCTAssertEqual(parsed.table("Order")?.column("items")?.isList, true)
        XCTAssertTrue(parsed.relations.contains(DBRelation(from: "Order", fromColumns: ["user"], to: "User", toColumns: ["_id"], kind: .manyToOne)))
        XCTAssertTrue(parsed.relations.contains { $0.from == "User" && $0.to == "User" && $0.kind == .manyToMany })
        XCTAssertTrue(parsed.relations.contains { $0.to == "User.address" && $0.kind == .embedded })
    }
}

final class SchemaDiscoveryTests: XCTestCase {
    private func encoded(_ path: String, _ text: String) -> String {
        SchemaDiscovery.marker + path + "\n" + Data(text.utf8).base64EncodedString() + "\n"
    }

    func testParsesOutputAndGroupsSources() {
        let output = encoded("./prisma/schema/user.prisma", "model User {\n id Int @id\n}")
            + encoded("./prisma/schema/post.prisma", "model Post {\n id Int @id\n}")
            + encoded("./prisma/migrations/20260101_init/migration.sql", "CREATE TABLE a (id int);")
            + encoded("./prisma/migrations/20260102_more/migration.sql", "ALTER TABLE a ADD COLUMN b int;")
            + encoded("./supabase/seed.sql", "INSERT INTO a VALUES (1);")
            + encoded("./docs/db.dbml", "Table a { id int }")
            + encoded("./src/models/user.ts", "const s = new Schema({ name: String })")
        let files = SchemaDiscovery.parseOutput(output)
        XCTAssertEqual(files.count, 7)
        XCTAssertEqual(files[0].path, "prisma/schema/user.prisma")
        let sources = SchemaDiscovery.sources(from: files)
        XCTAssertEqual(sources.map(\.kind), [.prisma, .sql, .dbml, .mongoose])
        XCTAssertEqual(sources[0].location, "prisma/schema")
        XCTAssertEqual(sources[0].files.map(\.path), ["prisma/schema/post.prisma", "prisma/schema/user.prisma"])
        XCTAssertEqual(sources[1].location, "prisma/migrations")
        XCTAssertEqual(sources[1].parse().table("a")?.columns.map(\.name), ["id", "b"])
        XCTAssertEqual(sources[3].location, "src/models")
    }

    func testWrappedBase64FromGNU() {
        let text = String(repeating: "CREATE TABLE wide (id int);\n", count: 20)
        let base64 = Data(text.utf8).base64EncodedString(options: .lineLength76Characters)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let files = SchemaDiscovery.parseOutput(SchemaDiscovery.marker + "./schema.sql\n" + base64 + "\n")
        XCTAssertEqual(files.first?.text, text)
    }

    func testCommandIsPortable() {
        let command = SchemaDiscovery.command
        XCTAssertFalse(command.contains("-printf"))
        XCTAssertTrue(command.contains("-prune"))
        XCTAssertTrue(command.contains("base64 <"))
    }
}

final class SchemaLayoutTests: XCTestCase {
    func testReferencedTablesSitLeftAndNothingOverlaps() throws {
        let schema = SQLSchemaParser.parse("""
        CREATE TABLE customers (id int PRIMARY KEY);
        CREATE TABLE orders (id int PRIMARY KEY, customer_id int REFERENCES customers(id));
        CREATE TABLE items (id int PRIMARY KEY, order_id int REFERENCES orders(id));
        CREATE TABLE notes (id int PRIMARY KEY, body text, extra text);
        CREATE TABLE logs (id int PRIMARY KEY);
        """)
        let metrics = SchemaLayout.Metrics()
        let positions = SchemaLayout.layout(schema, metrics: metrics)
        XCTAssertEqual(positions.count, 5)
        let customers = try XCTUnwrap(positions["customers"])
        let orders = try XCTUnwrap(positions["orders"])
        let items = try XCTUnwrap(positions["items"])
        XCTAssertLessThan(customers.x, orders.x)
        XCTAssertLessThan(orders.x, items.x)
        let rects = schema.tables.map { table -> CGRect in
            let point = positions[table.name]!
            return CGRect(x: point.x, y: point.y, width: metrics.cardWidth, height: metrics.height(rows: table.columns.count))
        }
        for i in rects.indices {
            for j in rects.indices where i < j {
                XCTAssertFalse(rects[i].intersects(rects[j]), "\(schema.tables[i].name) overlaps \(schema.tables[j].name)")
            }
        }
    }

    func testCyclesDoNotHang() {
        let schema = DBSchema(tables: [DBTable(name: "a"), DBTable(name: "b")], relations: [
            DBRelation(from: "a", fromColumns: ["b_id"], to: "b", toColumns: ["id"]),
            DBRelation(from: "b", fromColumns: ["a_id"], to: "a", toColumns: ["id"]),
        ])
        XCTAssertEqual(SchemaLayout.layout(schema).count, 2)
    }
}

final class SchemaExportAndEditingTests: XCTestCase {
    private let sql = """
    CREATE TABLE customers (id serial PRIMARY KEY, email varchar(255) NOT NULL UNIQUE, created_at timestamptz DEFAULT now());
    CREATE TABLE orders (id serial PRIMARY KEY, customer_id integer NOT NULL REFERENCES customers(id) ON DELETE CASCADE, note text);
    """

    func testSQLToPrismaRoundTrip() throws {
        let schema = SQLSchemaParser.parse(sql)
        let prisma = SchemaExport.render(schema, as: .prisma)
        XCTAssertTrue(prisma.contains("provider = \"postgresql\""))
        XCTAssertTrue(prisma.contains("model Customers {"))
        XCTAssertTrue(prisma.contains("@@map(\"customers\")"))
        XCTAssertTrue(prisma.contains("@relation(fields: [customer_id], references: [id], onDelete: Cascade)"))
        let reparsed = PrismaSchemaParser.parse(prisma)
        XCTAssertEqual(reparsed.tables.map(\.name), ["Customers", "Orders"])
        XCTAssertEqual(reparsed.table("Customers")?.column("email")?.isUnique, true)
        XCTAssertEqual(reparsed.relations.map(\.label), ["Orders.customer_id → Customers.id"])
        XCTAssertEqual(reparsed.relations.first?.onDelete, "Cascade")
    }

    func testPrismaToSQLRoundTrip() throws {
        let schema = PrismaSchemaParser.parse("""
        model Author {
          id    Int    @id @default(autoincrement())
          name  String
          books Book[]
        }
        model Book {
          id       Int    @id @default(autoincrement())
          title    String @default("untitled")
          author   Author @relation(fields: [authorId], references: [id])
          authorId Int
        }
        """)
        let ddl = SchemaExport.render(schema, as: .postgres)
        XCTAssertTrue(ddl.contains("\"id\" SERIAL NOT NULL PRIMARY KEY"))
        XCTAssertTrue(ddl.contains("DEFAULT 'untitled'"))
        let reparsed = SQLSchemaParser.parse(ddl)
        XCTAssertEqual(reparsed.tables.map(\.name), ["Author", "Book"])
        XCTAssertEqual(reparsed.relations.map(\.label), ["Book.authorId → Author.id"])
        XCTAssertFalse(SchemaExport.render(schema, as: .mysql).contains("SERIAL"))
    }

    func testDBMLRoundTrip() {
        let schema = SQLSchemaParser.parse(sql)
        let reparsed = DBMLParser.parse(SchemaExport.render(schema, as: .dbml))
        XCTAssertEqual(reparsed.tables.map(\.name), schema.tables.map(\.name))
        XCTAssertEqual(reparsed.relations.map(\.label), schema.relations.map(\.label))
        XCTAssertEqual(reparsed.table("customers")?.column("email")?.isUnique, true)
    }

    func testEditingKeepsRelationsInStep() throws {
        var schema = SQLSchemaParser.parse(sql)
        let added = try schema.addTable()
        XCTAssertEqual(added, "new_table")
        XCTAssertEqual(schema.table(added)?.primaryKey, ["id"])
        XCTAssertThrowsError(try schema.addTable("orders")) { error in
            XCTAssertEqual(error as? SchemaEditError, .duplicateTable("orders"))
        }
        try schema.renameTable("customers", to: "clients")
        XCTAssertEqual(schema.relations.first?.to, "clients")
        var column = try XCTUnwrap(schema.table("orders")?.column("customer_id"))
        column.name = "client_id"
        try schema.updateColumn(in: "orders", column: "customer_id", to: column)
        XCTAssertEqual(schema.relations.map(\.label), ["orders.client_id → clients.id"])
        let relation = try schema.addReference(from: added, to: "orders")
        XCTAssertEqual(relation.label, "new_table.orders_id → orders.id")
        XCTAssertEqual(schema.table(added)?.column("orders_id")?.type, "serial")
        schema.removeColumn("client_id", from: "orders")
        XCTAssertEqual(schema.relations.count, 1)
        schema.removeTable("orders")
        XCTAssertTrue(schema.relations.isEmpty)
    }
}

final class SchemaReviewFixTests: XCTestCase {
    func testDuplicateTablesDoNotCrashLayoutOrExport() {
        let source = SchemaSource(kind: .dbml, location: "db.dbml", files: [
            SchemaFile(path: "db.dbml", text: "Table users {\n id int [pk]\n}\nTable users {\n id int [pk]\n email text\n}"),
        ])
        let schema = source.parse()
        XCTAssertEqual(schema.tables.map(\.name), ["users"])
        XCTAssertEqual(schema.table("users")?.columns.map(\.name), ["id", "email"])
        var doubled = schema
        doubled.tables += schema.tables
        XCTAssertEqual(SchemaLayout.layout(doubled).count, 1)
        XCTAssertFalse(SchemaExport.render(doubled, as: .prisma).isEmpty)
    }

    func testMongooseSourceAndCompiledCopyDoNotDuplicateEmbeddedTables() {
        let text = "const userSchema = new Schema({ address: { city: String } })\nmodule.exports = mongoose.model('User', userSchema)"
        let schema = MongooseSchemaParser.parse(files: [text, text])
        XCTAssertEqual(schema.tables.count, Set(schema.tables.map(\.name)).count)
    }

    func testColumnsNamedLikeConstraintWordsAreKept() throws {
        let schema = SQLSchemaParser.parse("""
        CREATE TABLE files (
          id serial PRIMARY KEY,
          checksum text,
          checked_at timestamptz,
          unique_code varchar(32),
          key text,
          index_no integer,
          UNIQUE (unique_code),
          CHECK (index_no > 0)
        );
        CREATE TABLE things (
          id int,
          KEY idx_id (id),
          UNIQUE KEY uq_id (id)
        );
        """)
        let files = try XCTUnwrap(schema.table("files"))
        XCTAssertEqual(files.columns.map(\.name), ["id", "checksum", "checked_at", "unique_code", "key", "index_no"])
        XCTAssertTrue(files.column("unique_code")?.isUnique ?? false)
        XCTAssertEqual(schema.table("things")?.columns.map(\.name), ["id"])
    }

    func testEnumAndGeneratedDefaultsExport() {
        let schema = PrismaSchemaParser.parse("""
        datasource db {
          provider = "postgresql"
          url      = env("DATABASE_URL")
        }
        model Member {
          id   String @id @default(dbgenerated("gen_random_uuid()"))
          role Role   @default(DEVELOPER)
        }
        enum Role {
          OWNER
          DEVELOPER
        }
        """)
        let prisma = SchemaExport.render(schema, as: .prisma)
        XCTAssertTrue(prisma.contains("@default(DEVELOPER)"))
        XCTAssertTrue(prisma.contains("@default(dbgenerated(\"gen_random_uuid()\"))"))
        XCTAssertFalse(prisma.contains("dbgenerated(\"dbgenerated"))
        let sql = SchemaExport.render(schema, as: .postgres)
        XCTAssertTrue(sql.contains("DEFAULT 'DEVELOPER'"))
        XCTAssertTrue(sql.contains("DEFAULT gen_random_uuid()"))
    }

    func testCompositeTypesExportByName() {
        let schema = PrismaSchemaParser.parse("""
        datasource db {
          provider = "mongodb"
          url      = env("DATABASE_URL")
        }
        model Customer {
          id      String  @id @default(auto()) @map("_id") @db.ObjectId
          address Address
        }
        type Address {
          city String
        }
        """)
        let prisma = SchemaExport.render(schema, as: .prisma)
        XCTAssertFalse(prisma.contains("Unsupported(\"Address\")"))
        XCTAssertTrue(prisma.contains("Address"))
    }

    func testPrismaFilesWithTheirOwnDatasourceAreSeparateSources() {
        let datasource = { (provider: String) in "datasource db {\n  provider = \"\(provider)\"\n}\n" }
        let files = [
            SchemaFile(path: "prisma/schema.prisma", text: datasource("postgresql") + "model User {\n id Int @id\n}"),
            SchemaFile(path: "prisma/schema.sqlite.prisma", text: datasource("sqlite") + "model User {\n id Int @id\n}"),
            SchemaFile(path: "app/schema/main.prisma", text: datasource("postgresql")),
            SchemaFile(path: "app/schema/user.prisma", text: "model User {\n id Int @id\n}"),
        ]
        let sources = SchemaDiscovery.sources(from: files).filter { $0.kind == .prisma }
        XCTAssertEqual(sources.map(\.location), ["app/schema", "prisma/schema.prisma", "prisma/schema.sqlite.prisma"])
        XCTAssertEqual(sources[0].files.count, 2)
        XCTAssertEqual(sources[1].parse().dialect, .postgres)
        XCTAssertEqual(sources[2].parse().dialect, .sqlite)
    }
}

final class SchemaDiscoveryFolderTests: XCTestCase {
    func testFindsTheSchemaInsideTheChosenFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("acme app/prisma")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        datasource db {
          provider = "postgresql"
          url      = env("DATABASE_URL")
        }
        model Team {
          id   Int    @id
          name String
        }
        """.write(to: folder.appendingPathComponent("schema.prisma"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SchemaDiscovery.command(in: root.appendingPathComponent("acme app").path)]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let files = SchemaDiscovery.parseOutput(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(files.map(\.path), ["prisma/schema.prisma"])
        let sources = SchemaDiscovery.sources(from: files)
        XCTAssertEqual(sources.first?.title, "prisma/schema.prisma")
        XCTAssertEqual(sources.first?.parse().tables.map(\.name), ["Team"])
    }

    func testNoFolderKeepsTheSessionDirectory() {
        XCTAssertEqual(SchemaDiscovery.command(in: nil), SchemaDiscovery.command)
        XCTAssertTrue(SchemaDiscovery.command(in: "/srv/it's here").hasPrefix("cd '/srv/it'\\''s here' && "))
    }
}
