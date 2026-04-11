// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'family_tree.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class FamilyTreeAdapter extends TypeAdapter<FamilyTree> {
  @override
  final int typeId = 2;

  @override
  FamilyTree read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FamilyTree(
      id: fields[0] as String,
      name: fields[1] as String,
      description: fields[2] as String,
      creatorId: fields[3] as String,
      memberIds: (fields[4] as List).cast<String>(),
      createdAt: fields[5] as DateTime,
      updatedAt: fields[6] as DateTime,
      isPrivate: fields[7] as bool,
      members: (fields[8] as List).cast<String>(),
      publicSlug: fields[9] as String?,
      isCertified: fields[10] as bool? ?? false,
      certificationNote: fields[11] as String?,
      kind: fields[12] as TreeKind? ?? TreeKind.family,
    );
  }

  @override
  void write(BinaryWriter writer, FamilyTree obj) {
    writer
      ..writeByte(13)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.description)
      ..writeByte(3)
      ..write(obj.creatorId)
      ..writeByte(4)
      ..write(obj.memberIds)
      ..writeByte(5)
      ..write(obj.createdAt)
      ..writeByte(6)
      ..write(obj.updatedAt)
      ..writeByte(7)
      ..write(obj.isPrivate)
      ..writeByte(8)
      ..write(obj.members)
      ..writeByte(9)
      ..write(obj.publicSlug)
      ..writeByte(10)
      ..write(obj.isCertified)
      ..writeByte(11)
      ..write(obj.certificationNote)
      ..writeByte(12)
      ..write(obj.kind);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FamilyTreeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class TreeKindAdapter extends TypeAdapter<TreeKind> {
  @override
  final int typeId = 7;

  @override
  TreeKind read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 1:
        return TreeKind.friends;
      case 0:
      default:
        return TreeKind.family;
    }
  }

  @override
  void write(BinaryWriter writer, TreeKind obj) {
    switch (obj) {
      case TreeKind.family:
        writer.writeByte(0);
        return;
      case TreeKind.friends:
        writer.writeByte(1);
        return;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TreeKindAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
