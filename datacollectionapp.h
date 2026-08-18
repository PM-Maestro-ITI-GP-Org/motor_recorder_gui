#ifndef PDM_DATACOLLECTION_APP_H
#define PDM_DATACOLLECTION_APP_H

namespace PdM {
namespace DataCollection {

/*
 * Hands this app's page to the shell.
 *
 * Maestro's main.cpp calls this once, and the placeholder tab becomes the real
 * one. The app owns the URL rather than the shell hard-coding it, so moving or
 * renaming the page is a change inside this repository alone.
 *
 * Deliberately an explicit call and not a static initialiser: a self-registering
 * object in a static library is only linked in if something already references
 * the translation unit, so it would work in a normal build and silently vanish
 * under --gc-sections or a different linker.
 */
void registerWithShell();

} // namespace DataCollection
} // namespace PdM

#endif // PDM_DATACOLLECTION_APP_H
