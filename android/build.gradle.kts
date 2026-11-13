apply(from = "runtime-packaging.gradle")

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    configurations.configureEach {
        resolutionStrategy.eachDependency {
            // Flutter integration_test requests a dynamic 1.2+ test runner.
            // Keep the existing 1.2.0 artifact reproducible/offline-capable.
            if (requested.group == "androidx.test" && requested.name == "runner" &&
                requested.version == "1.2+") {
                useVersion("1.2.0")
                because("Pin the existing integration-test runner instead of fetching a version listing")
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
